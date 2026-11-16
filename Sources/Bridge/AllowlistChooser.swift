import AppKit
import Foundation

// Chat identifiers stay in the owner's local window and process memory.
final class AllowlistChooser:NSObject,NSTableViewDataSource,NSTableViewDelegate {
 let chats:[LocalConversation]
 let table=NSTableView()
 let view=NSScrollView(frame:NSRect(x:0,y:0,width:480,height:240))
 init(chats:[LocalConversation]) {
  self.chats=chats;super.init()
  let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("chat"));column.title="Conversation";column.width=460;table.addTableColumn(column)
  table.delegate=self;table.dataSource=self;table.allowsMultipleSelection=true;table.headerView=nil;view.documentView=table;view.hasVerticalScroller=true
 }
 func numberOfRows(in tableView:NSTableView)->Int {chats.count}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
  let label=NSTextField(labelWithString:chats[row].title);label.lineBreakMode = .byTruncatingMiddle;return label
 }
 func selected()->Set<String> {Set(table.selectedRowIndexes.compactMap{$0<chats.count ? chats[$0].guid:nil})}
}
