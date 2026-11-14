import Foundation

// In-memory policy building block only; no IPC listener or AI interface exists.
// A UI can grant future access only through explicit activation. Local is default.
struct AccessPolicy {
 enum Mode {case localOnly, assisted, full}
 private(set) var mode:Mode = .localOnly
 private var allowed:Set<String>=[]
 mutating func revoke(){mode = .localOnly;allowed.removeAll()}
 mutating func activateAssisted(_ chats:Set<String>, ownerConfirmed:Bool)->Bool {
  guard ownerConfirmed,!chats.isEmpty,chats.count<=1000,chats.allSatisfy({!$0.isEmpty && $0.utf8.count<=512 && !$0.utf8.contains(0)}) else {return false}
  allowed=chats;mode = .assisted;return true
 }
 mutating func activateFull(ownerConfirmed:Bool,cloudWarningAcknowledged:Bool)->Bool {
  guard ownerConfirmed && cloudWarningAcknowledged else{return false}
  allowed.removeAll();mode = .full;return true
 }
 func authorizes(chat:String?)->Bool {
  switch mode {case .localOnly:return false;case .assisted:guard let chat else{return false};return allowed.contains(chat);case .full:return true}
 }
}
