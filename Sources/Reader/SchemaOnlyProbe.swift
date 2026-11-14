import Foundation
import SQLite3
import Darwin

// Schema-only SQL is hardcoded below. The authorizer rejects all table rows,
// DDL, DML, ATTACH and unlisted pragmas, even if a future caller changes SQL.
enum SchemaOnlyProbe {
    struct Stamp: Equatable { let dev: UInt64; let inode: UInt64; let size: Int64; let seconds: Int; let nanos: Int }
    enum Failure: Error { case file(Int32), sqlite(Int32), changed, denied }
    struct Result {
        let tableResults: [String: Bool]
        let missingColumns: [String]
        let dateTypes: [String: String]
        let journal: String
        let sidecarsPresent: Bool
    }
    static let required: [(String, Set<String>)] = [
        ("message", ["date", "is_from_me", "text", "attributedBody"]),
        ("chat", ["guid"]),
        ("chat_message_join", ["chat_id", "message_id"]),
        ("attachment", ["mime_type", "total_bytes"]),
        ("message_attachment_join", ["message_id", "attachment_id"])
    ]
    static let dateNames: Set<String> = ["date", "date_read", "date_delivered", "date_edited"]
    static let authorizer: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, action, p1, p2, _, _ in
        let a = p1.map { String(cString:$0) } ?? ""
        let b = p2.map { String(cString:$0) } ?? ""
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ && (a == "sqlite_master" || a == "sqlite_schema") { return SQLITE_OK }
        if action == SQLITE_PRAGMA && a == "table_info" && SchemaOnlyProbe.required.contains(where: {$0.0 == b}) { return SQLITE_OK }
        if action == SQLITE_PRAGMA && a == "journal_mode" && b.isEmpty { return SQLITE_OK }
        return SQLITE_DENY
    }
    static func stamp(_ path:String) throws -> Stamp? {
        var s=stat()
        if lstat(path,&s) != 0 { if errno == ENOENT { return nil }; throw Failure.file(errno) }
        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.denied }
        return Stamp(dev:UInt64(s.st_dev),inode:UInt64(s.st_ino),size:s.st_size,seconds:s.st_mtimespec.tv_sec,nanos:s.st_mtimespec.tv_nsec)
    }
    static func inspect(folder:URL, filename:String) throws -> Result {
        guard filename == "chat.db" || filename == "fixture.sqlite" else { throw Failure.denied }
        let dbPath=folder.appendingPathComponent(filename).path
        let paths=[dbPath,dbPath+"-wal",dbPath+"-shm"]
        let before=try paths.map {try stamp($0)}
        guard before[0] != nil else {throw Failure.file(ENOENT)}
        let fd=dbPath.withCString { open($0,O_RDONLY|O_NOFOLLOW) }
        guard fd>=0 else {throw Failure.file(errno)}; _=close(fd)
        var db:OpaquePointer?
        let rc=sqlite3_open_v2(dbPath,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)
        guard rc==SQLITE_OK,let h=db else {if let db {sqlite3_close(db)};throw Failure.sqlite(rc)}
        var closed=false
        defer {if !closed {sqlite3_close(h)}}
        guard sqlite3_db_readonly(h,"main")==1 else {throw Failure.denied}
        guard sqlite3_exec(h,"PRAGMA query_only=ON",nil,nil,nil)==SQLITE_OK else {throw Failure.sqlite(sqlite3_errcode(h))}
        guard sqlite3_set_authorizer(h,authorizer,nil)==SQLITE_OK else {throw Failure.denied}
        func query(_ sql:String,_ row:(OpaquePointer)->Void)throws {
            var st:OpaquePointer?
            guard sqlite3_prepare_v2(h,sql,-1,&st,nil)==SQLITE_OK,let st else {throw Failure.sqlite(sqlite3_errcode(h))}
            defer {sqlite3_finalize(st)}
            while true {let x=sqlite3_step(st);if x==SQLITE_DONE {break};guard x==SQLITE_ROW else {throw Failure.sqlite(x)};row(st)}
        }
        var journal="unknown"
        try query("PRAGMA journal_mode") {st in if let p=sqlite3_column_text(st,0) {let value=String(cString:p).lowercased();journal=(value == "wal" || value == "delete") ? value : "other"}}
        var tables:[String:Bool]=[:];var missing:[String]=[];var dates:[String:String]=[:]
        for (table,requiredColumns) in required {
            // table strings are constants from the private allowlist, never user input.
            var names:Set<String>=[]
            try query("PRAGMA table_info('\(table)')") {st in
                guard let p=sqlite3_column_text(st,1) else{return}
                let name=String(cString:p);names.insert(name)
                if table == "message",dateNames.contains(name) {
                    let value=sqlite3_column_text(st,2).map {String(cString:$0).uppercased()} ?? ""
                    dates[name]=["INTEGER","REAL","TEXT","BLOB","NUMERIC",""].contains(value) ? value : "OTHER"
                }
            }
            tables[table] = !names.isEmpty
            for name in requiredColumns.subtracting(names).sorted() { missing.append("\(table).\(name)") }
        }
        guard sqlite3_close(h)==SQLITE_OK else {throw Failure.sqlite(sqlite3_errcode(h))};closed=true
        let after=try paths.map {try stamp($0)}
        guard before==after else {throw Failure.changed}
        return Result(tableResults:tables,missingColumns:missing,dateTypes:dates,journal:journal,sidecarsPresent:before[1] != nil && before[2] != nil)
    }
}
