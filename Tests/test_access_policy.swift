import Foundation
@main struct Tests {
 static func main(){
  var p=AccessPolicy();precondition(!p.authorizes(chat:"fake-a"))
  precondition(!p.activateAssisted(["fake-a"],ownerConfirmed:false));precondition(!p.authorizes(chat:"fake-a"))
  precondition(p.activateAssisted(["fake-a"],ownerConfirmed:true));precondition(p.authorizes(chat:"fake-a") && !p.authorizes(chat:"fake-b") && !p.authorizes(chat:nil))
  p.revoke();precondition(!p.authorizes(chat:"fake-a"))
  precondition(!p.activateFull(ownerConfirmed:true,cloudWarningAcknowledged:false));precondition(!p.authorizes(chat:nil))
  precondition(p.activateFull(ownerConfirmed:true,cloudWarningAcknowledged:true));precondition(p.authorizes(chat:nil) && p.authorizes(chat:"fake-b"))
  p.revoke();precondition(!p.authorizes(chat:nil));print("PASS policy defaults, allowlist, explicit activation, warning and revocation")
 }
}
