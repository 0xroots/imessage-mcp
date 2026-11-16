import Foundation
import CoreFoundation

// The app owns the folder scope and calls this router only on a verified connection.
enum BackendRouter {
 static let names:Set<String>=["list_conversations","get_messages","search_messages","get_recent_messages","get_attachment_metadata","get_attachment"]
 static func error(_ code:String)->[String:Any] { ["error":["code":code]] }

 static func response(authority:SessionAuthority,connection:UUID,folder:URL,filename:String,request:[String:Any])->[String:Any] {
  guard Set(request.keys).isSubset(of:["operation","arguments","client"]),let op=request["operation"] as? String,names.contains(op),let args=request["arguments"] as? [String:Any],args.count<=8 else{return error("invalid_request")}
  let allowedArguments:[String:Set<String>]=[
   "list_conversations":["query","limit","cursor"],
   "get_messages":["conversation_id","direction","date_from","date_to","limit","cursor"],
   "search_messages":["conversation_id","query","direction","date_from","date_to","limit","cursor"],
   "get_recent_messages":["conversation_id","direction","since","date_to","limit","cursor"],
   "get_attachment_metadata":["conversation_id","message_id","limit"],
   "get_attachment":["conversation_id","message_id","attachment_index"]
  ]
  guard Set(args.keys).isSubset(of:allowedArguments[op]!) else{return error("invalid_argument")}
  if let raw=args["conversation_id"],!(raw is String) {return error("invalid_argument")}
  if let raw=args["query"],!(raw is String) {return error("invalid_argument")}
  if let raw=args["direction"],!(raw is String) {return error("invalid_direction")}
  let chat=args["conversation_id"] as? String
  if let chat,!LocalMessageReader.validGUID(chat) {return error("invalid_argument")}
  if ["get_messages","get_attachment_metadata","get_attachment"].contains(op) && chat == nil {return error("conversation_required")}
  let query=args["query"] as? String ?? ""
  guard query.utf8.count<=512 else{return error("invalid_argument")}
  if op=="search_messages" && query.isEmpty {return error("query_required")}

  var direction:Int32 = -1
  if let raw=args["direction"] as? String {
   switch raw {case "incoming":direction=0;case "outgoing":direction=1;default:return error("invalid_direction")}
  }
  let rawLimit=args["limit"] as? NSNumber
  if args["limit"] != nil && (rawLimit == nil || CFGetTypeID(rawLimit!) == CFBooleanGetTypeID()) {return error("invalid_limit")}
  let requestedLimit=rawLimit?.intValue ?? 20
  guard requestedLimit>=1 && requestedLimit<=100,rawLimit == nil || rawLimit!.doubleValue == Double(requestedLimit) else{return error("invalid_limit")}
  if let v=args["cursor"],!(v is String) {return error("invalid_cursor")}

  let parser=ISO8601DateFormatter()
  func parseDate(_ key:String)->Date? {guard let s=args[key] as? String,s.utf8.count<=40 else{return nil};return parser.date(from:s)}
  for key in ["since","date_from","date_to"] where args[key] != nil {if parseDate(key)==nil {return error("invalid_date")}}
  let lower=parseDate(op=="get_recent_messages" ? "since":"date_from")
  let upper=parseDate("date_to")
  if op=="get_recent_messages" && lower == nil {return error("since_required")}
  if let lower,let upper,lower>=upper{return error("invalid_date")}

  let mayListAuthorizedChats = op=="list_conversations" || (chat == nil && ["search_messages","get_recent_messages"].contains(op))
  guard let ticket=authority.ticket(connection:connection,chat:chat,allowAssistedListing:mayListAuthorizedChats) else{return error("access_denied")}
  let allowedGUIDs:Set<String>?
  switch ticket.mode {case .full:allowedGUIDs=nil;case .assisted(let ids):allowedGUIDs=ids}
  if let chat,let allowedGUIDs,!allowedGUIDs.contains(where:{$0.utf8.elementsEqual(chat.utf8)}) {return error("access_denied")}

  var boundArgs=args;boundArgs.removeValue(forKey:"cursor")
  guard let bindingData=try? JSONSerialization.data(withJSONObject:["operation":op,"arguments":boundArgs],options:[.sortedKeys]),bindingData.count<=3_072 else{return error("invalid_request")}
  let binding=bindingData.base64EncodedString()
  let token=args["cursor"] as? String

  do {
   let result:[String:Any]
   switch op {
   case "list_conversations":
    var offset:Int64=0
    if let token {guard let value=authority.resolveCursor(ticket,token:token,binding:binding),value>=0 else{return error("invalid_cursor")};offset=value}
    let all=try LocalMessageReader.conversations(folder:folder,filename:filename,allowedGUIDs:allowedGUIDs)
    let visible=all.filter{query.isEmpty || $0.matches(query)}
    guard offset<=Int64(visible.count) else{return error("invalid_cursor")}
    let start=Int(offset),page=Array(visible.dropFirst(start).prefix(requestedLimit)),next=start+page.count<visible.count ? Int64(start+page.count):nil
    let nextToken=next.flatMap{authority.issueCursor(ticket,value:$0,binding:binding)}
    if next != nil && nextToken == nil {return error("cursor_limit")}
    result=["conversations":page.map{entry in ["conversation_id":entry.guid,"title":entry.title,"group_name":entry.name as Any? ?? NSNull(),"participants":Array(entry.participants.prefix(20)),"participant_count":entry.participants.count,"last_activity":entry.lastDate.flatMap{LocalMessageReader.date($0)}.map{parser.string(from:$0)} as Any? ?? NSNull()] as [String:Any]},"next_cursor":nextToken as Any? ?? NSNull()]

   case "get_messages","search_messages","get_recent_messages":
    var messageCursor:LocalSearchCursor?
    if let token {
     guard let value=authority.resolveMessageCursor(ticket,token:token,binding:binding) else{return error("invalid_cursor")}
     messageCursor=LocalSearchCursor(timestampNanos:value.timestampNanos,rowID:value.rowID,chatGUID:value.chatGUID)
    }
    let effectiveLimit=min(requestedLimit,ticket.limits.maxMessagesPerRequest,ticket.remainingMessages)
    guard effectiveLimit>0,authority.reserveMessages(ticket,count:effectiveLimit) else{return error("message_budget_exhausted")}
    let term=op=="search_messages" ? query:""
    let page=try LocalMessageReader.globalSearch(folder:folder,filename:filename,term:term,chatGUID:chat,allowedGUIDs:allowedGUIDs,direction:direction,lower:lower,upper:upper,before:messageCursor,scanLimit:effectiveLimit)
    let rows=page.hits.map{hit -> [String:Any] in
     ["conversation_id":hit.chatGUID,"message_id":hit.message.rowID,"date":LocalMessageReader.date(hit.message.rawDate).map{parser.string(from:$0)} as Any? ?? NSNull(),"direction":hit.message.outgoing ? "outgoing":"incoming","text":hit.message.text as Any? ?? NSNull(),"decoder_status":hit.message.status,"attachment_count":hit.message.attachmentCount]
    }
    let sessionCursor=page.nextCursor.map{SessionAuthority.MessageCursor(timestampNanos:$0.timestampNanos,rowID:$0.rowID,chatGUID:$0.chatGUID)}
    let nextToken=sessionCursor.flatMap{authority.issueCursor(ticket,value:$0,binding:binding)}
    if sessionCursor != nil && nextToken == nil {return error("cursor_limit")}
    result=["messages":rows,"next_cursor":nextToken as Any? ?? NSNull(),"unsupported_scanned":page.unsupportedCount,"candidate_count":page.examinedCount]

   case "get_attachment_metadata":
    guard let id=args["message_id"] as? NSNumber,CFGetTypeID(id) != CFBooleanGetTypeID(),id.int64Value>0,id.doubleValue==Double(id.int64Value),let chat else{return error("message_required")}
    guard authority.reserveMessages(ticket,count:1) else{return error("message_budget_exhausted")}
    let attachmentLimit=min(requestedLimit,ticket.limits.maxMessagesPerRequest)
    let items=try LocalMessageReader.attachments(folder:folder,filename:filename,guid:chat,messageID:id.int64Value,limit:attachmentLimit)
    result=["attachments":items.enumerated().map{["index":$0.offset,"filename":$0.element.name as Any? ?? NSNull(),"mime_type":$0.element.mimeType as Any? ?? NSNull(),"size":$0.element.size as Any? ?? NSNull()] as [String:Any]}]

   case "get_attachment":
    // Reads the file only when the owner enabled attachments for this bridge run.
    guard authority.attachmentsEnabled else{return error("attachments_disabled")}
    guard let id=args["message_id"] as? NSNumber,CFGetTypeID(id) != CFBooleanGetTypeID(),id.int64Value>0,id.doubleValue==Double(id.int64Value),let chat else{return error("message_required")}
    var attachmentIndex=0
    if let raw=args["attachment_index"] {
     guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.intValue>=0,n.intValue<50,n.doubleValue==Double(n.intValue) else{return error("invalid_argument")}
     attachmentIndex=n.intValue
    }
    guard authority.reserveMessages(ticket,count:1) else{return error("message_budget_exhausted")}
    guard let source=try LocalMessageReader.attachmentSource(folder:folder,filename:filename,guid:chat,messageID:id.int64Value,index:attachmentIndex) else{return error("attachment_not_found")}
    let declared=Int(clamping:source.size ?? 0)
    guard declared<=SessionAuthority.Limits.maxAttachmentFileBytes else{return error("attachment_too_large")}
    guard authority.reserveAttachmentBytes(ticket,count:declared>0 ? declared:SessionAuthority.Limits.maxAttachmentFileBytes) else{return error("attachment_budget_exhausted")}
    do {
     let loaded=try AttachmentLoader.load(source:source,folder:folder,maxBytes:SessionAuthority.Limits.maxAttachmentFileBytes)
     var info:[String:Any]=["filename":source.name as Any? ?? NSNull(),"mime_type":loaded.mimeType,"size":loaded.byteCount]
     if let pages=loaded.pageCount {info["pages"]=pages;info["pages_returned_as_images"]=loaded.images.count}
     result=["attachment":info,"text":loaded.text as Any? ?? NSNull(),"images":loaded.images.map{$0.base64EncodedString()}]
    } catch let failure as AttachmentLoadError {
     switch failure {
     case .notAvailable:return error("attachment_file_unavailable")
     case .tooLarge:return error("attachment_too_large")
     case .unsupportedType:return error("attachment_type_unsupported")
     case .unreadable:return error("attachment_unreadable")
     }
    }
   default:return error("invalid_request")
   }
   guard authority.isCurrent(ticket) else{return error("access_revoked")}
   return result
  } catch LocalReaderError.searchBudgetExceeded {return Self.error("search_budget_exceeded")}
  catch LocalReaderError.unsupportedSchema {return Self.error("unsupported_schema")}
  catch LocalReaderError.invalidInput {return Self.error("invalid_argument")}
  catch {return Self.error("reader_failed")}
 }
}
