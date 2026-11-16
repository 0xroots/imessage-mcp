import Foundation
import SQLite3
import Darwin

// Local GUI use only: results must never be logged or sent to another process.
// Caller must hold the folder security scope through the entire operation.
enum LocalReaderError: Error { case invalidInput, unavailable, sqlite(Int32), modified, searchBudgetExceeded, unsupportedSchema }
struct LocalConversation {
 let guid: String; let identifier: String; let lastDate:Int64?
 // Group name set in Messages and the handles of its members (both optional, bounded).
 var name:String?=nil; var participants:[String]=[]
 // Best human label: group name, else member handles, else the raw chat identifier.
 var title:String { if let n=name,!n.isEmpty {return n}; if participants.count>1 {return participants.prefix(4).joined(separator:", ")+(participants.count>4 ? " +\(participants.count-4)":"")}; return identifier }
 func matches(_ query:String)->Bool { identifier.localizedCaseInsensitiveContains(query) || (name?.localizedCaseInsensitiveContains(query) ?? false) || participants.contains{$0.localizedCaseInsensitiveContains(query)} }
}
struct LocalMessage { let rowID:Int64; let rawDate:Int64; let outgoing:Bool; let text:String?; let status:String; let attachmentCount:Int64 }
struct LocalSearchHit { let chatGUID:String; let chatIdentifier:String; let message:LocalMessage }
struct LocalSearchCursor: Equatable { let timestampNanos:Int64?; let rowID:Int64; let chatGUID:String }
struct LocalSearchPage { let hits:[LocalSearchHit]; let nextCursor:LocalSearchCursor?; let unsupportedCount:Int; let examinedCount:Int }
struct LocalAttachment {let name:String?;let mimeType:String?;let size:Int64?}
// Where one attachment lives on disk (relative to the Messages folder) and what the database says about it.
struct LocalAttachmentSource {let name:String?;let mimeType:String?;let size:Int64?;let storedPath:String?}

// SQLite runs the text predicate itself so the database applies it alongside
// the chat, direction, date, and cursor filters. These functions only inspect
// bounded UTF-8 text and the narrow synthetic archive decoder.
private let localTextContains: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, argc, argv in
 guard argc==2,let argv else {sqlite3_result_int(context,0);return}
 guard sqlite3_value_type(argv[0])==SQLITE_TEXT,sqlite3_value_type(argv[1])==SQLITE_TEXT else {sqlite3_result_int(context,0);return}
 let textBytes=Int(sqlite3_value_bytes(argv[0])),termBytes=Int(sqlite3_value_bytes(argv[1]))
 guard textBytes<=16_384,termBytes<=512,let textPointer=sqlite3_value_text(argv[0]),let termPointer=sqlite3_value_text(argv[1]) else {sqlite3_result_int(context,0);return}
 let textData=Data(bytes:textPointer,count:textBytes),termData=Data(bytes:termPointer,count:termBytes)
 let matches=String(data:textData,encoding:.utf8).flatMap{body in String(data:termData,encoding:.utf8).map{body.localizedCaseInsensitiveContains($0)}} ?? false
 sqlite3_result_int(context,matches ? 1:0)
}
private let localArchiveContains: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, argc, argv in
 guard argc==2,let argv else {sqlite3_result_int(context,0);return}
 guard sqlite3_value_type(argv[0])==SQLITE_BLOB,sqlite3_value_type(argv[1])==SQLITE_TEXT else {sqlite3_result_int(context,0);return}
 let bodyBytes=Int(sqlite3_value_bytes(argv[0])),termBytes=Int(sqlite3_value_bytes(argv[1]))
 guard bodyBytes<=BodyDecoder.limit,termBytes<=512,let bodyPointer=sqlite3_value_blob(argv[0]),let termPointer=sqlite3_value_text(argv[1]) else {sqlite3_result_int(context,0);return}
 let bodyData=Data(bytes:bodyPointer,count:bodyBytes),termData=Data(bytes:termPointer,count:termBytes)
 guard case .decoded(let body)=BodyDecoder.inspect(bodyData),let term=String(data:termData,encoding:.utf8) else {sqlite3_result_int(context,0);return}
 sqlite3_result_int(context,body.localizedCaseInsensitiveContains(term) ? 1:0)
}
private final class SearchProgressBudget { var remainingCallbacks:Int; init(operations:Int,interval:Int){remainingCallbacks=max(1,(operations+interval-1)/interval)} }
private let localSearchProgress: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
 guard let context else{return 1}
 let budget=Unmanaged<SearchProgressBudget>.fromOpaque(context).takeUnretainedValue()
 budget.remainingCallbacks -= 1
 return budget.remainingCallbacks<=0 ? 1:0
}
private let localSQLiteAuthorizer: @convention(c) (UnsafeMutableRawPointer?,Int32,UnsafePointer<CChar>?,UnsafePointer<CChar>?,UnsafePointer<CChar>?,UnsafePointer<CChar>?) -> Int32 = { _,action,p1,p2,p3,p4 in
 if action==SQLITE_SELECT {return p4==nil ? SQLITE_OK:SQLITE_DENY}
 if action==SQLITE_READ {
  guard p4==nil,let tablePointer=p1 else{return SQLITE_DENY}
  let table=String(cString:tablePointer).lowercased(),column=p2.map{String(cString:$0).lowercased()} ?? ""
  let allowedTables=["message","chat","chat_message_join","attachment","message_attachment_join","handle","chat_handle_join"]
  if column.isEmpty {
   guard allowedTables.contains(table) else{return SQLITE_DENY}
   return p3==nil || (p3.map{String(cString:$0)}=="main") ? SQLITE_OK:SQLITE_DENY
  }
  guard let databasePointer=p3,String(cString:databasePointer)=="main" else{return SQLITE_DENY}
  let columns:[String:Set<String>]=[
   "message":["rowid","date","is_from_me","text","attributedbody"],
   "chat":["rowid","guid","chat_identifier","display_name"],
   "handle":["rowid","id"],
   "chat_handle_join":["chat_id","handle_id"],
   "chat_message_join":["chat_id","message_id"],
   "attachment":["rowid","transfer_name","mime_type","total_bytes","filename"],
   "message_attachment_join":["message_id","attachment_id"]
  ]
  return columns[table]?.contains(column)==true ? SQLITE_OK:SQLITE_DENY
 }
 if action==SQLITE_FUNCTION {
  return p4==nil ? SQLITE_OK:SQLITE_DENY
 }
 return SQLITE_DENY
}

enum LocalMessageReader {
 static let maximumPage=100
 static let maximumSearchVMOperations=10_000_000
 static func session<T>(folder:URL, filename:String, work:(OpaquePointer)throws->T)throws->T {
  guard filename == "chat.db" || filename == "fixture.sqlite" else {throw LocalReaderError.invalidInput}
  let path=folder.appendingPathComponent(filename).path
  let paths=[path,path+"-wal",path+"-shm"]
  let before=try paths.map{try SchemaOnlyProbe.stamp($0)}
  guard before.allSatisfy({$0 != nil}) else {throw LocalReaderError.unavailable}
  for p in paths { for flag in [O_WRONLY,O_RDWR] {
   let fd=p.withCString{open($0,flag|O_NOFOLLOW)}
   if fd>=0 {_ = close(fd);throw LocalReaderError.unavailable}
   guard errno == EPERM || errno == EACCES else {throw LocalReaderError.unavailable}
  }}
  let fd=path.withCString{open($0,O_RDONLY|O_NOFOLLOW)};guard fd>=0 else {throw LocalReaderError.unavailable};_ = close(fd)
  var connection:OpaquePointer?;let code=sqlite3_open_v2(path,&connection,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)
  guard code==SQLITE_OK,let db=connection else {if let connection {sqlite3_close(connection)};throw LocalReaderError.sqlite(code)}
  var closed=false;defer{if !closed {sqlite3_close(db)}}
  guard sqlite3_db_readonly(db,"main")==1 else {throw LocalReaderError.unavailable}
  _ = sqlite3_limit(db,SQLITE_LIMIT_LENGTH,1_048_576)
  guard sqlite3_exec(db,"PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN",nil,nil,nil)==SQLITE_OK else {throw LocalReaderError.sqlite(sqlite3_errcode(db))}
  guard sqlite3_set_authorizer(db,localSQLiteAuthorizer,nil)==SQLITE_OK else{throw LocalReaderError.unavailable}
  let result:T
  do {result=try work(db)} catch {_ = sqlite3_set_authorizer(db,nil,nil);throw error}
  guard sqlite3_set_authorizer(db,nil,nil)==SQLITE_OK else{throw LocalReaderError.unavailable}
  guard sqlite3_exec(db,"ROLLBACK",nil,nil,nil)==SQLITE_OK else {throw LocalReaderError.sqlite(sqlite3_errcode(db))}
  guard sqlite3_close(db)==SQLITE_OK else {throw LocalReaderError.unavailable};closed=true
  guard try paths.map({try SchemaOnlyProbe.stamp($0)})==before else {throw LocalReaderError.modified}
  return result
 }
 static func prepare(_ db:OpaquePointer,_ sql:String)throws->OpaquePointer {var stmt:OpaquePointer?;let rc=sqlite3_prepare_v3(db,sql,-1,UInt32(SQLITE_PREPARE_NO_VTAB),&stmt,nil);guard rc==SQLITE_OK,let stmt else {throw sqliteFailure(rc)};return stmt}
 static func sqliteFailure(_ rc:Int32)->LocalReaderError {if rc==SQLITE_INTERRUPT{return .searchBudgetExceeded};if rc==SQLITE_ERROR || rc==SQLITE_SCHEMA || rc==SQLITE_AUTH{return .unsupportedSchema};return .sqlite(rc)}
 static func bind(_ s:OpaquePointer,_ index:Int32,_ value:String)throws {let destructor=unsafeBitCast(-1,to:sqlite3_destructor_type.self);let count=value.utf8.count;guard count<=Int(Int32.max) else{throw LocalReaderError.invalidInput};let rc=value.withCString{sqlite3_bind_text(s,index,$0,Int32(count),destructor)};guard rc==SQLITE_OK else {throw LocalReaderError.sqlite(rc)}}
 static func validGUID(_ value:String)->Bool {!value.isEmpty && value.utf8.count<=512 && !value.utf8.contains(0)}
 static func registerSearchFunctions(_ db:OpaquePointer)throws {
  let flags=SQLITE_UTF8|SQLITE_DETERMINISTIC|SQLITE_DIRECTONLY
  let textRC=sqlite3_create_function_v2(db,"local_text_contains",2,flags,nil,localTextContains,nil,nil,nil)
  let archiveRC=sqlite3_create_function_v2(db,"local_archive_contains",2,flags,nil,localArchiveContains,nil,nil,nil)
  guard textRC==SQLITE_OK,archiveRC==SQLITE_OK else{throw LocalReaderError.sqlite(textRC != SQLITE_OK ? textRC:archiveRC)}
 }
 static func string(_ s:OpaquePointer,_ column:Int32)->String? {guard sqlite3_column_type(s,column)==SQLITE_TEXT,let p=sqlite3_column_text(s,column) else {return nil};let n=Int(sqlite3_column_bytes(s,column));guard n<=16_384 else{return nil};return String(bytes:UnsafeBufferPointer(start:p,count:n),encoding:.utf8)}
 static func attachments(folder:URL,filename:String,guid:String,messageID:Int64,limit:Int)throws->[LocalAttachment] {
  guard validGUID(guid),messageID>0,limit>0,limit<=100 else {throw LocalReaderError.invalidInput}
  return try session(folder:folder,filename:filename){db in
   let sql="""
   SELECT a.transfer_name,a.mime_type,a.total_bytes FROM chat c
   JOIN chat_message_join cm ON cm.chat_id=c.ROWID JOIN message m ON m.ROWID=cm.message_id
   JOIN message_attachment_join ma ON ma.message_id=m.ROWID JOIN attachment a ON a.ROWID=ma.attachment_id
   WHERE c.guid COLLATE BINARY=?1 COLLATE BINARY AND m.ROWID=?2 ORDER BY a.ROWID LIMIT ?3
   """
   let stmt=try prepare(db,sql);defer{sqlite3_finalize(stmt)};try bind(stmt,1,guid)
   guard sqlite3_bind_int64(stmt,2,messageID)==SQLITE_OK,sqlite3_bind_int(stmt,3,Int32(limit))==SQLITE_OK else {throw LocalReaderError.unavailable}
   var rows:[LocalAttachment]=[]
   while true {let rc=sqlite3_step(stmt);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw sqliteFailure(rc)}
    let size=sqlite3_column_type(stmt,2)==SQLITE_INTEGER ? sqlite3_column_int64(stmt,2):nil
    rows.append(LocalAttachment(name:string(stmt,0),mimeType:string(stmt,1),size:size))
   };return rows
  }
 }
 // The i-th attachment (0-based, same order as `attachments`) of one message in one chat,
 // with its stored path. The path is only used by AttachmentLoader and is never returned.
 static func attachmentSource(folder:URL,filename:String,guid:String,messageID:Int64,index:Int)throws->LocalAttachmentSource? {
  guard validGUID(guid),messageID>0,index>=0,index<100 else {throw LocalReaderError.invalidInput}
  return try session(folder:folder,filename:filename){db in
   let sql="""
   SELECT a.transfer_name,a.mime_type,a.total_bytes,a.filename FROM chat c
   JOIN chat_message_join cm ON cm.chat_id=c.ROWID JOIN message m ON m.ROWID=cm.message_id
   JOIN message_attachment_join ma ON ma.message_id=m.ROWID JOIN attachment a ON a.ROWID=ma.attachment_id
   WHERE c.guid COLLATE BINARY=?1 COLLATE BINARY AND m.ROWID=?2 ORDER BY a.ROWID LIMIT 1 OFFSET ?3
   """
   let stmt=try prepare(db,sql);defer{sqlite3_finalize(stmt)};try bind(stmt,1,guid)
   guard sqlite3_bind_int64(stmt,2,messageID)==SQLITE_OK,sqlite3_bind_int(stmt,3,Int32(index))==SQLITE_OK else {throw LocalReaderError.unavailable}
   let rc=sqlite3_step(stmt);if rc==SQLITE_DONE {return nil};guard rc==SQLITE_ROW else {throw sqliteFailure(rc)}
   let size=sqlite3_column_type(stmt,2)==SQLITE_INTEGER ? sqlite3_column_int64(stmt,2):nil
   return LocalAttachmentSource(name:string(stmt,0),mimeType:string(stmt,1),size:size,storedPath:string(stmt,3))
  }
 }
 // Distinct plausible seconds/nanoseconds ranges only. Ambiguous or implausible
 // values are explicitly unavailable rather than presented as a guessed date.
 static func date(_ raw:Int64)->Date? {
  let value:Double
  if raw >= 100_000_000 && raw <= 4_000_000_000 { value=Double(raw) }
  else if raw >= 100_000_000_000_000_000 && raw <= 4_000_000_000_000_000_000 {value=Double(raw)/1_000_000_000}
  else {return nil}
  return Date(timeIntervalSinceReferenceDate:value)
 }
 static func timestampNanos(_ raw:Int64)->Int64? {
  if raw >= 100_000_000 && raw <= 4_000_000_000 {return raw*1_000_000_000}
  if raw >= 100_000_000_000_000_000 && raw <= 4_000_000_000_000_000_000 {return raw}
  return nil
 }
 static func timestampNanos(_ date:Date)->Int64? {
  let value=date.timeIntervalSinceReferenceDate*1_000_000_000
  guard value.isFinite,value >= -9_223_372_036_854_775_808.0,value < 9_223_372_036_854_775_808.0 else{return nil}
  return Int64(value.rounded(.up))
 }
 static func globalSearch(folder:URL,filename:String,term:String,chatGUID:String?=nil,allowedGUIDs:Set<String>?=nil,direction:Int32 = -1,lower:Date?=nil,upper:Date?=nil,before:LocalSearchCursor?=nil,scanLimit:Int=200,progressBudget:Int=maximumSearchVMOperations)throws->LocalSearchPage {
  guard term.utf8.count<=512,chatGUID.map(validGUID) ?? true,[-1,0,1].contains(direction),scanLimit>0,scanLimit<=500,progressBudget>0,progressBudget<=maximumSearchVMOperations else {throw LocalReaderError.invalidInput}
  if let lower,let upper,lower >= upper {throw LocalReaderError.invalidInput}
  let lowerKey=lower.flatMap(timestampNanos),upperKey=upper.flatMap(timestampNanos)
  if lower != nil && lowerKey == nil || upper != nil && upperKey == nil {throw LocalReaderError.invalidInput}
  if let allowedGUIDs {
   guard allowedGUIDs.count<=1000,allowedGUIDs.allSatisfy(validGUID) else{throw LocalReaderError.invalidInput}
   if allowedGUIDs.isEmpty {return LocalSearchPage(hits:[],nextCursor:nil,unsupportedCount:0,examinedCount:0)}
   if let chatGUID,!allowedGUIDs.contains(where:{$0.utf8.elementsEqual(chatGUID.utf8)}) {throw LocalReaderError.invalidInput}
  }
  guard before == nil || (before!.rowID>0 && validGUID(before!.chatGUID)) else{throw LocalReaderError.invalidInput}
  return try session(folder:folder,filename:filename){db in
   try registerSearchFunctions(db)
   let progressInterval=min(1_000,progressBudget)
   let progress=SearchProgressBudget(operations:progressBudget,interval:progressInterval)
   sqlite3_progress_handler(db,Int32(progressInterval),localSearchProgress,Unmanaged.passUnretained(progress).toOpaque())
   defer{sqlite3_progress_handler(db,0,nil,nil);withExtendedLifetime(progress){}}
   let normalized="CASE WHEN typeof(m.date)='integer' AND m.date BETWEEN 100000000 AND 4000000000 THEN m.date*1000000000 WHEN typeof(m.date)='integer' AND m.date BETWEEN 100000000000000000 AND 4000000000000000000 THEN m.date ELSE NULL END"
   var candidateBindings:[(OpaquePointer)throws->Void]=[]
   func candidateText(_ value:String)->String {let index=Int32(candidateBindings.count+1);candidateBindings.append{try bind($0,index,value)};return "?\(index)"}
   func candidateInt(_ value:Int64)->String {let index=Int32(candidateBindings.count+1);candidateBindings.append{stmt in guard sqlite3_bind_int64(stmt,index,value)==SQLITE_OK else{throw LocalReaderError.unavailable}};return "?\(index)"}
   var predicates=["typeof(c.guid)='text'","length(c.guid)>0","instr(c.guid,char(0))=0","m.is_from_me IN (0,1)"]
   if let chatGUID {predicates.append("c.guid COLLATE BINARY=\(candidateText(chatGUID)) COLLATE BINARY")}
   if let allowedGUIDs {
    let ids=allowedGUIDs.sorted{Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))}
    predicates.append("c.guid COLLATE BINARY IN (\(ids.map{candidateText($0)}.joined(separator:",")))")
   }
   if direction != -1 {predicates.append("m.is_from_me=\(candidateInt(Int64(direction)))")}
   if let lowerKey {predicates.append("(\(normalized))>=\(candidateInt(lowerKey))")}
   if let upperKey {predicates.append("(\(normalized))<\(candidateInt(upperKey))")}
   if let before {
    let row1=candidateInt(before.rowID),row2=candidateInt(before.rowID),guid=candidateText(before.chatGUID)
    if let timestamp=before.timestampNanos {
     let time1=candidateInt(timestamp),time2=candidateInt(timestamp)
     predicates.append("((\(normalized)) IS NULL OR (\(normalized))<\(time1) OR ((\(normalized))=\(time2) AND (m.ROWID<\(row1) OR (m.ROWID=\(row2) AND c.guid COLLATE BINARY>\(guid) COLLATE BINARY))))")
    } else {
     predicates.append("((\(normalized)) IS NULL AND (m.ROWID<\(row1) OR (m.ROWID=\(row2) AND c.guid COLLATE BINARY>\(guid) COLLATE BINARY)))")
    }
   }
   let candidateLimit=candidateInt(Int64(scanLimit+1))
   let candidateSQL="""
   SELECT DISTINCT m.ROWID,(\(normalized)) AS sort_timestamp,c.guid COLLATE BINARY AS chat_guid
   FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
   WHERE \(predicates.joined(separator:" AND "))
   ORDER BY (sort_timestamp IS NULL) ASC,sort_timestamp DESC,m.ROWID DESC,c.guid COLLATE BINARY ASC
   LIMIT \(candidateLimit)
   """
   let candidatesStatement=try prepare(db,candidateSQL);defer{sqlite3_finalize(candidatesStatement)}
   for bind in candidateBindings {try bind(candidatesStatement)}
   var candidates:[LocalSearchCursor]=[]
   while true {
    let rc=sqlite3_step(candidatesStatement);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw sqliteFailure(rc)}
    guard sqlite3_column_type(candidatesStatement,0)==SQLITE_INTEGER,let guid=string(candidatesStatement,2),validGUID(guid) else{throw LocalReaderError.unavailable}
    let rowID=sqlite3_column_int64(candidatesStatement,0);guard rowID>0 else{throw LocalReaderError.unavailable}
    let timestamp=sqlite3_column_type(candidatesStatement,1)==SQLITE_INTEGER ? sqlite3_column_int64(candidatesStatement,1):nil
    candidates.append(LocalSearchCursor(timestampNanos:timestamp,rowID:rowID,chatGUID:guid))
   }
   let hasMore=candidates.count>scanLimit
   if hasMore {candidates.removeLast()}
   let next=hasMore ? candidates.last:nil
   var hits:[LocalSearchHit]=[],unsupported=0
   if !candidates.isEmpty {
    var contentBindings:[(OpaquePointer)throws->Void]=[]
    func contentText(_ value:String)->String {let index=Int32(contentBindings.count+1);contentBindings.append{try bind($0,index,value)};return "?\(index)"}
    func contentInt(_ value:Int64)->String {let index=Int32(contentBindings.count+1);contentBindings.append{stmt in guard sqlite3_bind_int64(stmt,index,value)==SQLITE_OK else{throw LocalReaderError.unavailable}};return "?\(index)"}
    let keys=candidates.map{cursor in "(m.ROWID=\(contentInt(cursor.rowID)) AND c.guid COLLATE BINARY=\(contentText(cursor.chatGUID)) COLLATE BINARY)"}.joined(separator:" OR ")
    var textPredicate=""
    if !term.isEmpty {
     let search=contentText(term)
     textPredicate="AND CASE WHEN (\(keys)) THEN CASE WHEN m.text IS NOT NULL THEN local_text_contains(m.text,\(search))=1 WHEN m.attributedBody IS NOT NULL THEN local_archive_contains(m.attributedBody,\(search))=1 ELSE 0 END ELSE 0 END"
    }
    let contentSQL="""
    SELECT DISTINCT m.ROWID,m.date,m.is_from_me,
    CASE WHEN typeof(m.text)='text' AND length(CAST(m.text AS BLOB))<=16384 THEN m.text END,
    CASE WHEN m.text IS NULL AND typeof(m.attributedBody)='blob' AND length(m.attributedBody)<=16384 THEN m.attributedBody END,
    m.text IS NOT NULL,m.attributedBody IS NOT NULL,
    (SELECT COUNT(a.ROWID) FROM message_attachment_join j JOIN attachment a ON a.ROWID=j.attachment_id WHERE j.message_id=m.ROWID),
    c.guid,c.chat_identifier,(\(normalized)) AS sort_timestamp
    FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
    WHERE (\(keys)) \(textPredicate)
    ORDER BY (sort_timestamp IS NULL) ASC,sort_timestamp DESC,m.ROWID DESC,c.guid COLLATE BINARY ASC
    """
    let contentStatement=try prepare(db,contentSQL);defer{sqlite3_finalize(contentStatement)}
    for bind in contentBindings {try bind(contentStatement)}
    while true {
     let rc=sqlite3_step(contentStatement);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw sqliteFailure(rc)}
     guard sqlite3_column_type(contentStatement,0)==SQLITE_INTEGER,sqlite3_column_type(contentStatement,2)==SQLITE_INTEGER,let guid=string(contentStatement,8),validGUID(guid) else{throw LocalReaderError.unavailable}
     let row=sqlite3_column_int64(contentStatement,0),raw=sqlite3_column_type(contentStatement,1)==SQLITE_INTEGER ? sqlite3_column_int64(contentStatement,1):0
     let directionValue=sqlite3_column_int(contentStatement,2);guard directionValue==0 || directionValue==1 else{throw LocalReaderError.unavailable}
     var text:String?,status="empty"
     if sqlite3_column_int(contentStatement,5) != 0 {text=string(contentStatement,3);status=text == nil ? "unsupported":"plain"}
     else if sqlite3_column_int(contentStatement,6) != 0 {
      if sqlite3_column_type(contentStatement,4)==SQLITE_BLOB,let pointer=sqlite3_column_blob(contentStatement,4) {
       let data=Data(bytes:pointer,count:Int(sqlite3_column_bytes(contentStatement,4)));switch BodyDecoder.inspect(data){case .decoded(let value):text=value;status="archive";default:status="unsupported"}
      } else {status="unsupported"}
     }
     if status=="unsupported" {unsupported += 1}
     let message=LocalMessage(rowID:row,rawDate:raw,outgoing:directionValue==1,text:text,status:status,attachmentCount:sqlite3_column_int64(contentStatement,7))
     hits.append(LocalSearchHit(chatGUID:guid,chatIdentifier:string(contentStatement,9) ?? "[unknown]",message:message))
    }
   }
   return LocalSearchPage(hits:hits,nextCursor:next,unsupportedCount:unsupported,examinedCount:candidates.count)
  }
 }
 static func conversations(folder:URL,filename:String,allowedGUIDs:Set<String>?=nil)throws->[LocalConversation] {
  if let allowedGUIDs {
   guard allowedGUIDs.count<=1000,allowedGUIDs.allSatisfy(validGUID) else{throw LocalReaderError.invalidInput}
   if allowedGUIDs.isEmpty {return []}
  }
  return try session(folder:folder,filename:filename){db in
   let ids=allowedGUIDs?.sorted{Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))} ?? []
   var bindings:[(OpaquePointer)throws->Void]=[]
   let scope:String
   if allowedGUIDs != nil {
    let placeholders=ids.map { value -> String in
     let index=Int32(bindings.count+1);bindings.append{try bind($0,index,value)};return "?\(index)"
    }.joined(separator:",")
    scope=" AND guid COLLATE BINARY IN (\(placeholders))"
   } else {scope=""}
   // Last activity: the newest message of each chat through the (chat_id, message_id) key,
   // one bounded lookup per chat. If this query is unavailable the list still works, undated.
   let lastDate="(SELECT m.date FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id WHERE j.chat_id=chat.ROWID ORDER BY j.message_id DESC LIMIT 1)"
   func list(_ dateExpression:String,_ nameExpression:String,_ memberExpression:String)throws->[LocalConversation] {
    let s=try prepare(db,"SELECT guid,chat_identifier,\(dateExpression),\(nameExpression),\(memberExpression) FROM chat WHERE guid IS NOT NULL AND typeof(guid)='text' AND length(guid)>0 AND instr(guid,char(0))=0\(scope) ORDER BY ROWID DESC LIMIT 1000");defer{sqlite3_finalize(s)}
    for bind in bindings {try bind(s)}
    var rows:[LocalConversation]=[]
    while true {
     let rc=sqlite3_step(s);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw sqliteFailure(rc)}
     guard let guid=string(s,0),validGUID(guid) else {continue}
     let date=sqlite3_column_type(s,2)==SQLITE_INTEGER ? sqlite3_column_int64(s,2):nil
     var row=LocalConversation(guid:guid,identifier:string(s,1) ?? "[unknown]",lastDate:date)
     if let name=string(s,3)?.trimmingCharacters(in:.whitespacesAndNewlines),!name.isEmpty {row.name=String(name.prefix(200))}
     if let members=string(s,4) {row.participants=members.split(separator:"\u{1F}").prefix(50).map{String($0.prefix(64))}.filter{!$0.isEmpty}}
     rows.append(row)
    }
    return rows
   }
   // Group name and member handles, each bounded. Older or odd schemas fall back step by step.
   let nameSQL="CASE WHEN typeof(display_name)='text' AND length(CAST(display_name AS BLOB))<=1024 THEN display_name END"
   let memberSQL="(SELECT group_concat(h.id,char(31)) FROM chat_handle_join ch JOIN handle h ON h.ROWID=ch.handle_id WHERE ch.chat_id=chat.ROWID AND typeof(h.id)='text' AND length(h.id)<=64)"
   let rows:[LocalConversation]
   if let dated=(try? list(lastDate,nameSQL,memberSQL)) ?? (try? list(lastDate,"NULL","NULL")) {
    // Most recent conversations first; undated ones last, original order kept for ties.
    rows=dated.enumerated().sorted{a,b in
     let x=a.element.lastDate.flatMap{LocalMessageReader.date($0)},y=b.element.lastDate.flatMap{LocalMessageReader.date($0)}
     switch (x,y) {
     case let (l?,r?): return l==r ? a.offset<b.offset : l>r
     case (_?,nil): return true
     case (nil,_?): return false
     default: return a.offset<b.offset
     }
    }.map{$0.element}
   } else {rows=try list("NULL","NULL","NULL")}
   return rows
  }
 }
 static func messages(folder:URL,filename:String,guid:String,search:String="",beforeRow:Int64?=nil,limit:Int=50)throws->[LocalMessage] {
  guard validGUID(guid),search.utf8.count<=512,limit>0,limit<=maximumPage else {throw LocalReaderError.invalidInput}
  return try session(folder:folder,filename:filename){db in
   let sql="""
   SELECT DISTINCT m.ROWID,m.date,m.is_from_me,
   CASE WHEN typeof(m.text)='text' AND length(CAST(m.text AS BLOB))<=16384 THEN m.text END,
   CASE WHEN typeof(m.attributedBody)='blob' AND length(m.attributedBody)<=16384 THEN m.attributedBody END,
   m.text IS NOT NULL,m.attributedBody IS NOT NULL,
   (SELECT COUNT(a.ROWID) FROM message_attachment_join j JOIN attachment a ON a.ROWID=j.attachment_id WHERE j.message_id=m.ROWID)
   FROM chat c JOIN chat_message_join cm ON cm.chat_id=c.ROWID JOIN message m ON m.ROWID=cm.message_id
   WHERE c.guid COLLATE BINARY=?1 COLLATE BINARY AND (?2=0 OR m.ROWID<?2) ORDER BY m.ROWID DESC LIMIT ?3
   """
   let s=try prepare(db,sql);defer{sqlite3_finalize(s)};try bind(s,1,guid)
   guard sqlite3_bind_int64(s,2,beforeRow ?? 0)==SQLITE_OK,sqlite3_bind_int(s,3,Int32(limit))==SQLITE_OK else {throw LocalReaderError.unavailable}
   var rows:[LocalMessage]=[]
   while true {
    let rc=sqlite3_step(s);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw sqliteFailure(rc)}
    guard sqlite3_column_type(s,0)==SQLITE_INTEGER,sqlite3_column_type(s,1)==SQLITE_INTEGER,sqlite3_column_type(s,2)==SQLITE_INTEGER else {throw LocalReaderError.unavailable}
    let d=sqlite3_column_int(s,2);guard d==0 || d==1 else {throw LocalReaderError.unavailable}
    var text:String?,status="empty"
    if sqlite3_column_int(s,5) != 0 {text=string(s,3);status=text == nil ? "unsupported" : "plain"}
    else if sqlite3_column_int(s,6) != 0 {
     if sqlite3_column_type(s,4)==SQLITE_BLOB,let p=sqlite3_column_blob(s,4) {
      let data=Data(bytes:p,count:Int(sqlite3_column_bytes(s,4)));switch BodyDecoder.inspect(data){case .decoded(let value):text=value;status="archive";default:status="unsupported"}
     } else {status="unsupported"}
    }
    if search.isEmpty || (text?.localizedCaseInsensitiveContains(search) ?? false) {
     rows.append(LocalMessage(rowID:sqlite3_column_int64(s,0),rawDate:sqlite3_column_int64(s,1),outgoing:d==1,text:text,status:status,attachmentCount:sqlite3_column_int64(s,7)))
    }
   }
   return rows
  }
 }
}
