import AppKit
import Foundation

// UI runs in the signed, network-denied application; no output is logged.
final class LocalBrowserWindow:NSObject,NSWindowDelegate {
 let folder:URL
 var window:NSWindow!
 var popup:NSPopUpButton!
 var search:NSSearchField!
 var scope:NSPopUpButton!
 var direction:NSPopUpButton!
 var fromDate:NSTextField!
 var toDate:NSTextField!
 var textView:NSTextView!
 var note:NSTextField!
 var scroll:NSScrollView!
 var chats:[LocalConversation]=[]
 var cursor:LocalSearchCursor?
 var began=false
 let formatter:DateFormatter = {let f=DateFormatter();f.dateStyle = .medium;f.timeStyle = .short;return f}()
 let day:DateFormatter = {let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd";f.isLenient=false;return f}()
 init(folder:URL) {self.folder=folder;super.init()}
 func show() {
  window=NSWindow(contentRect:NSRect(x:130,y:130,width:900,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  window.title="Messages — Local Only";window.delegate=self
  // Other apps cannot capture or record this window, and it locks itself when left alone.
  window.sharingType = .none
  startAutoLock()
  popup=NSPopUpButton(frame:NSRect(x:15,y:605,width:300,height:30));popup.target=self;popup.action=#selector(selectConversation);window.contentView?.addSubview(popup)
  search=NSSearchField(frame:NSRect(x:325,y:605,width:275,height:30));search.placeholderString="Search messages";window.contentView?.addSubview(search)
  scope=NSPopUpButton(frame:NSRect(x:610,y:605,width:145,height:30));scope.addItems(withTitles:["Current chat","All chats"]);window.contentView?.addSubview(scope)
  let find=NSButton(title:"Search",target:self,action:#selector(refresh));find.frame=NSRect(x:760,y:605,width:120,height:30);window.contentView?.addSubview(find)
  direction=NSPopUpButton(frame:NSRect(x:15,y:565,width:145,height:30));direction.addItems(withTitles:["All senders","Incoming","Outgoing"]);window.contentView?.addSubview(direction)
  fromDate=NSTextField(frame:NSRect(x:175,y:567,width:135,height:24));fromDate.placeholderString="From YYYY-MM-DD";window.contentView?.addSubview(fromDate)
  toDate=NSTextField(frame:NSRect(x:320,y:567,width:135,height:24));toDate.placeholderString="To YYYY-MM-DD";window.contentView?.addSubview(toDate)
  let older=NSButton(title:"Load next",target:self,action:#selector(loadOlder));older.frame=NSRect(x:760,y:565,width:120,height:30);window.contentView?.addSubview(older)
  note=NSTextField(wrappingLabelWithString:"Local only. AI and MCP unavailable. Unsupported archives are excluded from text searches.");note.frame=NSRect(x:15,y:520,width:870,height:38);window.contentView?.addSubview(note)
  scroll=NSScrollView(frame:NSRect(x:15,y:15,width:870,height:495));scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true
  textView=NSTextView(frame:scroll.bounds);textView.isEditable=false;scroll.documentView=textView;window.contentView?.addSubview(scroll)
  do {chats=try LocalMessageReader.conversations(folder:folder,filename:"chat.db");popup.removeAllItems();popup.addItems(withTitles:chats.map{chat in
   let date=chat.lastDate.flatMap{LocalMessageReader.date($0)}.map{formatter.string(from:$0)} ?? "Date unavailable"
   return "\(chat.identifier) · \(date)"
  });if !chats.isEmpty {refresh()}}
  catch {note.stringValue="Unable to read conversations safely. Check read-only folder access and WAL/SHM availability."}
  window.makeKeyAndOrderFront(nil)
 }
 @objc func selectConversation(){scope.selectItem(at:0);search.stringValue="";refresh()}
 @objc func refresh(){cursor=nil;began=false;textView.string="";loadPage()}
 @objc func loadOlder(){guard began && cursor != nil else{return};loadPage()}
 private func loadPage(){
  let guid:String?
  if scope.indexOfSelectedItem==0 {guard popup.indexOfSelectedItem >= 0,popup.indexOfSelectedItem < chats.count else{return};guid=chats[popup.indexOfSelectedItem].guid} else {guid=nil}
  let lower=fromDate.stringValue.isEmpty ? nil:day.date(from:fromDate.stringValue)
  let end=toDate.stringValue.isEmpty ? nil:day.date(from:toDate.stringValue)
  guard (fromDate.stringValue.isEmpty || lower != nil),(toDate.stringValue.isEmpty || end != nil) else {note.stringValue="Invalid date. Use YYYY-MM-DD.";return}
  let upper=end.flatMap{Calendar.current.date(byAdding:.day,value:1,to:$0)}
  let d:Int32=direction.indexOfSelectedItem==1 ? 0 : (direction.indexOfSelectedItem==2 ? 1 : -1)
  do {
   let page=try LocalMessageReader.globalSearch(folder:folder,filename:"chat.db",term:search.stringValue,chatGUID:guid,direction:d,lower:lower,upper:upper,before:cursor)
   began=true;cursor=page.nextCursor
   let display=page.hits.map {hit in
    let row=hit.message,body=row.text ?? "[\(row.status)]"
    let when=LocalMessageReader.date(row.rawDate).map{formatter.string(from:$0)} ?? "Date unavailable"
    return "\(hit.chatIdentifier) · \(row.outgoing ? "Outgoing" : "Incoming") · \(when) · attachments \(row.attachmentCount)\n\(body)\n"
   }.joined(separator:"\n")
   let old=scroll.contentView.bounds.origin;textView.string += display;scroll.contentView.scroll(to:old);scroll.reflectScrolledClipView(scroll.contentView)
   note.stringValue="Local only · Scanned up to 200 messages · Unsupported in this batch: \(page.unsupportedCount) · \(cursor == nil ? "End of scan":"Use Load next to continue") · AI unavailable"
  } catch {note.stringValue="Read stopped: access, WAL/SHM integrity, invalid dates, or database compatibility issue."}
 }
 private var lastActivity=Date()
 private var lockTimer:Timer?
 private var activityMonitor:Any?
 private func startAutoLock() {
  lastActivity=Date()
  activityMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.scrollWheel]){[weak self] event in self?.lastActivity=Date();return event}
  lockTimer=Timer.scheduledTimer(withTimeInterval:15,repeats:true){[weak self] _ in
   guard let self,Date().timeIntervalSince(self.lastActivity)>=300 else{return}
   self.window.close()
  }
 }
 func windowWillClose(_ notification:Notification){
  lockTimer?.invalidate();lockTimer=nil
  if let monitor=activityMonitor {NSEvent.removeMonitor(monitor);activityMonitor=nil}
  textView.string="";chats=[]
  folder.stopAccessingSecurityScopedResource()
 }
}
