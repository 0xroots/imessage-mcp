import Foundation
import ApplicationServices

// The server performs validation, connection authorization, the local
// confirmation and one-shot approval before invoking either implementation.
// A transport must consume canDispatch immediately before its one attempt.
protocol MessageSending {
 func sendMessage(recipient: String, text: String, canDispatch: () -> Bool) -> String
}

struct AppleEventsSender: MessageSending {
 func sendMessage(recipient: String, text: String, canDispatch: () -> Bool) -> String {
  let result = MessagesAppleEventSender().send(phoneE164: recipient, text: text, canDispatch: canDispatch)
  switch result.outcome {
  case .notAttempted: return "not_attempted"
  case .acceptedByMessages: return "submitted"
  case .indeterminate: return "unknown"
  }
 }
}

#if MCP_SYNTHETIC || MCP_TEST_AUTO
// Compiled only into explicitly designated test builds. The test harness can
// inject an outcome directly; no request, message content, CLI flag, persisted
// setting or environment variable selects this transport or its outcome.
final class MockSender: MessageSending {
 enum Outcome { case success, failure, timeout }
 private let outcome: Outcome
 private let lock = NSLock()
 private var attempts = 0
 private var completed = 0

 init(outcome: Outcome = .success) { self.outcome = outcome }

 // No recipient or text is recorded, even in the synthetic test environment.
 func counts() -> (attempts: Int, completed: Int) {
  lock.lock(); defer { lock.unlock() }
  return (attempts, completed)
 }

 func sendMessage(recipient: String, text: String, canDispatch: () -> Bool) -> String {
  guard MessagesAppleEventSender.isValidE164(recipient),
        MessagesAppleEventSender.isValidMessageText(text), canDispatch() else {
   return "not_attempted"
  }
  lock.lock(); attempts += 1; lock.unlock()
  let status: String
  switch outcome {
  case .success: status = "mock_submitted"
  case .failure: status = "not_attempted"
  case .timeout: status = "unknown"
  }
  lock.lock(); completed += 1; lock.unlock()
  return status
 }
}
#endif

enum MessagesSendOutcome: String, Equatable {
 case notAttempted
 case acceptedByMessages
 case indeterminate
}

enum MessagesSendReason: String, Equatable {
 case invalidRecipient
 case invalidText
 case accountLookupFailed
 case noUniqueEnabledIMessageAccount
 case invalidAccountIdentifier
 case participantLookupFailed
 case participantMismatch
 case dispatchAuthorizationRevoked
 case accountRecheckFailed
 case accountChangedBeforeSend
 case automationConsentRequired
 case timeoutOrAppleEventFailure
}

struct MessagesSendResult: Equatable {
 let outcome: MessagesSendOutcome
 let reason: MessagesSendReason?

 static let accepted = MessagesSendResult(outcome: .acceptedByMessages, reason: nil)
 static func notAttempted(_ reason: MessagesSendReason) -> MessagesSendResult {
  MessagesSendResult(outcome: .notAttempted, reason: reason)
 }
 static func indeterminate(_ reason: MessagesSendReason = .timeoutOrAppleEventFailure) -> MessagesSendResult {
  MessagesSendResult(outcome: .indeterminate, reason: reason)
 }
}

enum MessagesAccountLookup: Equatable {
 case accountIDs([String])
 case failed
}

struct MessagesResolvedParticipant: Equatable {
 let handle: String
 let accountID: String
}

enum MessagesParticipantLookup: Equatable {
 case resolved(MessagesResolvedParticipant)
 case failed
}

enum MessagesAccountState: Equatable {
 case enabledIMessage
 case unavailable
 case failed
}

enum MessagesAppleEventSubmission: Equatable {
 case accepted
 case accountUnavailable
 case consentRequired
 case indeterminate
}

protocol MessagesAppleEventTransport {
 func enabledIMessageAccountIDs() -> MessagesAccountLookup
 func resolveParticipant(accountID: String, phoneE164: String) -> MessagesParticipantLookup
 func recheckAccount(accountID: String) -> MessagesAccountState
 func submit(accountID: String, phoneE164: String, text: String) -> MessagesAppleEventSubmission
}

struct MessagesAppleEventSender {
 static let maxPhoneUTF8Bytes = 16
 static let maxAccountIDUTF8Bytes = 128
 static let maxTextUTF8Bytes = 4_096

 private let transport: any MessagesAppleEventTransport

 init(transport: any MessagesAppleEventTransport = SystemMessagesAppleEventTransport()) {
  self.transport = transport
 }

 // Synchronous by design. Call from a worker thread after local approval;
 // AESendMessage is documented as thread-safe and each Apple event has a bound.
 func send(phoneE164: String, text: String, canDispatch: () -> Bool) -> MessagesSendResult {
  guard Self.isValidE164(phoneE164) else { return .notAttempted(.invalidRecipient) }
  guard Self.isValidMessageText(text) else { return .notAttempted(.invalidText) }

  let accountID: String
  switch transport.enabledIMessageAccountIDs() {
  case .failed:
   return .notAttempted(.accountLookupFailed)
  case .accountIDs(let ids):
   guard ids.count == 1 else { return .notAttempted(.noUniqueEnabledIMessageAccount) }
   guard Self.isValidAccountID(ids[0]) else { return .notAttempted(.invalidAccountIdentifier) }
   accountID = ids[0]
  }

  guard case .resolved(let participant) = transport.resolveParticipant(accountID: accountID, phoneE164: phoneE164) else {
   return .notAttempted(.participantLookupFailed)
  }
  guard Self.equalUTF8(participant.handle, phoneE164), Self.equalUTF8(participant.accountID, accountID) else {
   return .notAttempted(.participantMismatch)
  }

  switch transport.recheckAccount(accountID: accountID) {
  case .enabledIMessage:
   break
  case .unavailable:
   return .notAttempted(.accountChangedBeforeSend)
  case .failed:
   return .notAttempted(.accountRecheckFailed)
  }

  // This is intentionally the last local check before the one send attempt,
  // so Stop/revocation after account or participant preflight prevents dispatch.
  guard canDispatch() else { return .notAttempted(.dispatchAuthorizationRevoked) }

  // Exactly one submission attempt. A timeout may arrive after Messages accepted
  // the command, so it is indeterminate and must never trigger a retry.
  switch transport.submit(accountID: accountID, phoneE164: phoneE164, text: text) {
  case .accepted:
   return .accepted
  case .accountUnavailable:
   return .notAttempted(.accountChangedBeforeSend)
  case .consentRequired:
   return .notAttempted(.automationConsentRequired)
  case .indeterminate:
   return .indeterminate()
  }
 }

 static func isValidE164(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard (2...maxPhoneUTF8Bytes).contains(bytes.count), bytes[0] == 43,
        (49...57).contains(bytes[1]) else { return false }
  return bytes.dropFirst(2).allSatisfy { (48...57).contains($0) }
 }

 static func isValidMessageText(_ value: String) -> Bool {
  let length = value.utf8.count
  return (1...maxTextUTF8Bytes).contains(length) && !value.unicodeScalars.contains { $0.value == 0 }
 }

 static func isValidAccountID(_ value: String) -> Bool {
  let length = value.utf8.count
  guard (1...maxAccountIDUTF8Bytes).contains(length), !value.contains(":"),
        value.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return false }
  return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
 }

 static func equalUTF8(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.elementsEqual(rhs.utf8)
 }
}

enum MessagesAppleEventCode {
 static func from(_ fourCharacters: String) -> OSType {
  let bytes = Array(fourCharacters.utf8)
  precondition(bytes.count == 4)
  return bytes.reduce(0) { ($0 << 8) | OSType($1) }
 }

 static let messagesBundleID = "com.apple.MobileSMS"
 static let messagesSuite = from("icht")
 static let sendCommand = from("send")
 static let toParameter = from("TO  ")
 static let directObject = from("----")
 static let coreSuite = from("core")
 static let getDataCommand = from("getd")
 static let errorNumber = from("errn")
 static let replyEventClass = from("aevt")
 static let answerEvent = from("ansr")

 static let desiredClass = from("want")
 static let container = from("from")
 static let keyForm = from("form")
 static let keyData = from("seld")
 static let objectSpecifier = from("obj ")
 static let absoluteOrdinal = from("abso")
 static let formAbsolutePosition = from("indx")
 static let formPropertyID = from("prop")
 static let formUniqueID = from("ID  ")
 static let accountClass = from("icsv")
 static let participantClass = from("pres")
 static let propertyClass = from("prop")
 static let accountIDProperty = from("ID  ")
 static let enabledProperty = from("enbl")
 static let serviceTypeProperty = from("styp")
 static let participantHandleProperty = from("hndl")
 static let participantAccountProperty = from("icsv")
 static let iMessageServiceType = from("sims")
 static let appleEventList = from("list")
 static let boolean = from("bool")
 static let enumeration = from("enum")
 static let signedInt16 = from("shor")
 static let signedInt32 = from("long")
 static let null = from("null")
}

enum MessagesAppleEventBuilder {
 static func sendEvent(accountID: String, phoneE164: String, text: String) -> NSAppleEventDescriptor? {
  guard MessagesAppleEventSender.isValidAccountID(accountID),
        MessagesAppleEventSender.isValidE164(phoneE164),
        MessagesAppleEventSender.isValidMessageText(text),
        let account = accountSpecifier(accountID: accountID) else { return nil }

  let participantID = accountID + ":" + phoneE164
  let target = NSAppleEventDescriptor(bundleIdentifier: MessagesAppleEventCode.messagesBundleID)
  guard let participant = objectSpecifier(
   desiredClass: MessagesAppleEventCode.participantClass,
   keyForm: MessagesAppleEventCode.formUniqueID,
   keyData: NSAppleEventDescriptor(string: participantID),
   container: account
  ) else { return nil }

  let event = NSAppleEventDescriptor(
   eventClass: MessagesAppleEventCode.messagesSuite,
   eventID: MessagesAppleEventCode.sendCommand,
   targetDescriptor: target,
   returnID: AEReturnID(kAutoGenerateReturnID),
   transactionID: AETransactionID(kAnyTransactionID)
  )
  event.setParam(NSAppleEventDescriptor(string: text), forKeyword: MessagesAppleEventCode.directObject)
  event.setParam(participant, forKeyword: MessagesAppleEventCode.toParameter)
  return event
 }

 static func getEveryAccountPropertyEvent(_ propertyCode: OSType) -> NSAppleEventDescriptor? {
  let allOrdinal = NSAppleEventDescriptor(enumCode: MessagesAppleEventCode.from("all "))
  let target = NSAppleEventDescriptor(bundleIdentifier: MessagesAppleEventCode.messagesBundleID)
  guard let all = NSAppleEventDescriptor(
   descriptorType: MessagesAppleEventCode.absoluteOrdinal,
   data: allOrdinal.data
  ), let accounts = objectSpecifier(
   desiredClass: MessagesAppleEventCode.accountClass,
   keyForm: MessagesAppleEventCode.formAbsolutePosition,
   keyData: all,
   container: .null()
  ), let property = objectSpecifier(
   desiredClass: MessagesAppleEventCode.propertyClass,
   keyForm: MessagesAppleEventCode.formPropertyID,
   keyData: NSAppleEventDescriptor(typeCode: propertyCode),
   container: accounts
  ) else { return nil }

  let event = NSAppleEventDescriptor(
   eventClass: MessagesAppleEventCode.coreSuite,
   eventID: MessagesAppleEventCode.getDataCommand,
   targetDescriptor: target,
   returnID: AEReturnID(kAutoGenerateReturnID),
   transactionID: AETransactionID(kAnyTransactionID)
  )
  event.setParam(property, forKeyword: MessagesAppleEventCode.directObject)
  return event
 }

 static func getAccountPropertyEvent(accountID: String, propertyCode: OSType) -> NSAppleEventDescriptor? {
  guard MessagesAppleEventSender.isValidAccountID(accountID),
        let account = accountSpecifier(accountID: accountID),
        let property = objectSpecifier(
         desiredClass: MessagesAppleEventCode.propertyClass,
         keyForm: MessagesAppleEventCode.formPropertyID,
         keyData: NSAppleEventDescriptor(typeCode: propertyCode),
         container: account
        ) else { return nil }
  let target = NSAppleEventDescriptor(bundleIdentifier: MessagesAppleEventCode.messagesBundleID)
  let event = NSAppleEventDescriptor(
   eventClass: MessagesAppleEventCode.coreSuite,
   eventID: MessagesAppleEventCode.getDataCommand,
   targetDescriptor: target,
   returnID: AEReturnID(kAutoGenerateReturnID),
   transactionID: AETransactionID(kAnyTransactionID)
  )
  event.setParam(property, forKeyword: MessagesAppleEventCode.directObject)
  return event
 }

 static func participantPropertyEvent(accountID: String, phoneE164: String, propertyCode: OSType) -> NSAppleEventDescriptor? {
  guard MessagesAppleEventSender.isValidAccountID(accountID),
        MessagesAppleEventSender.isValidE164(phoneE164),
        let account = accountSpecifier(accountID: accountID),
        let participant = objectSpecifier(
         desiredClass: MessagesAppleEventCode.participantClass,
         keyForm: MessagesAppleEventCode.formUniqueID,
         keyData: NSAppleEventDescriptor(string: accountID + ":" + phoneE164),
         container: account
        ), let property = objectSpecifier(
         desiredClass: MessagesAppleEventCode.propertyClass,
         keyForm: MessagesAppleEventCode.formPropertyID,
         keyData: NSAppleEventDescriptor(typeCode: propertyCode),
         container: participant
        ) else { return nil }
  let target = NSAppleEventDescriptor(bundleIdentifier: MessagesAppleEventCode.messagesBundleID)

  let event = NSAppleEventDescriptor(
   eventClass: MessagesAppleEventCode.coreSuite,
   eventID: MessagesAppleEventCode.getDataCommand,
   targetDescriptor: target,
   returnID: AEReturnID(kAutoGenerateReturnID),
   transactionID: AETransactionID(kAnyTransactionID)
  )
  event.setParam(property, forKeyword: MessagesAppleEventCode.directObject)
  return event
 }

 static func participantAccountIDEvent(accountID: String, phoneE164: String) -> NSAppleEventDescriptor? {
  guard MessagesAppleEventSender.isValidAccountID(accountID),
        MessagesAppleEventSender.isValidE164(phoneE164),
        let account = accountSpecifier(accountID: accountID),
        let participant = objectSpecifier(
         desiredClass: MessagesAppleEventCode.participantClass,
         keyForm: MessagesAppleEventCode.formUniqueID,
         keyData: NSAppleEventDescriptor(string: accountID + ":" + phoneE164),
         container: account
        ), let accountProperty = objectSpecifier(
         desiredClass: MessagesAppleEventCode.propertyClass,
         keyForm: MessagesAppleEventCode.formPropertyID,
         keyData: NSAppleEventDescriptor(typeCode: MessagesAppleEventCode.participantAccountProperty),
         container: participant
        ), let accountIDProperty = objectSpecifier(
         desiredClass: MessagesAppleEventCode.propertyClass,
         keyForm: MessagesAppleEventCode.formPropertyID,
         keyData: NSAppleEventDescriptor(typeCode: MessagesAppleEventCode.accountIDProperty),
         container: accountProperty
        ) else { return nil }
  let target = NSAppleEventDescriptor(bundleIdentifier: MessagesAppleEventCode.messagesBundleID)

  let event = NSAppleEventDescriptor(
   eventClass: MessagesAppleEventCode.coreSuite,
   eventID: MessagesAppleEventCode.getDataCommand,
   targetDescriptor: target,
   returnID: AEReturnID(kAutoGenerateReturnID),
   transactionID: AETransactionID(kAnyTransactionID)
  )
  event.setParam(accountIDProperty, forKeyword: MessagesAppleEventCode.directObject)
  return event
 }

 static func objectSpecifier(
  desiredClass: OSType,
  keyForm: OSType,
  keyData: NSAppleEventDescriptor,
  container: NSAppleEventDescriptor
 ) -> NSAppleEventDescriptor? {
  guard let rawContainer = container.aeDesc, let rawKeyData = keyData.aeDesc else { return nil }
  var containerDesc = rawContainer.pointee
  var keyDataDesc = rawKeyData.pointee
  var result = AEDesc(descriptorType: MessagesAppleEventCode.null, dataHandle: nil)
  let status = CreateObjSpecifier(desiredClass, &containerDesc, keyForm, &keyDataDesc, false, &result)
  guard status == noErr else {
   _ = AEDisposeDesc(&result)
   return nil
  }
  return NSAppleEventDescriptor(aeDescNoCopy: &result)
 }

 private static func accountSpecifier(accountID: String) -> NSAppleEventDescriptor? {
  objectSpecifier(
   desiredClass: MessagesAppleEventCode.accountClass,
   keyForm: MessagesAppleEventCode.formUniqueID,
   keyData: NSAppleEventDescriptor(string: accountID),
   container: .null()
  )
 }
}

struct SystemMessagesAppleEventTransport: MessagesAppleEventTransport {
 // 30 s: the first event may wait for the macOS Automation consent prompt.
 private static let readTimeoutTicks: Int = 30 * 60
 // Last Apple Event status (OSStatus or app error number) for diagnostics only.
 static var lastEventStatus: Int32 = 0
 private static let sendTimeoutTicks: Int = 8 * 60
 private static let maximumAccounts = 8

 func enabledIMessageAccountIDs() -> MessagesAccountLookup {
  guard let idReply = Self.getEveryAccountProperty(MessagesAppleEventCode.accountIDProperty),
        let idValue = idReply.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject),
        let ids = Self.listOrScalar(idValue), ids.count <= Self.maximumAccounts else { return .failed }
  var eligible: [String] = []
  for idValue in ids {
   guard let accountID = idValue.stringValue,
         MessagesAppleEventSender.isValidAccountID(accountID) else { return .failed }
   switch Self.readAccountState(accountID: accountID) {
   case .enabledIMessage:
    eligible.append(accountID)
   case .unavailable:
    break
   case .failed:
    return .failed
   }
  }
  return .accountIDs(eligible)
 }

 func resolveParticipant(accountID: String, phoneE164: String) -> MessagesParticipantLookup {
  guard let handleEvent = MessagesAppleEventBuilder.participantPropertyEvent(
   accountID: accountID, phoneE164: phoneE164,
   propertyCode: MessagesAppleEventCode.participantHandleProperty
  ), let accountEvent = MessagesAppleEventBuilder.participantAccountIDEvent(
   accountID: accountID, phoneE164: phoneE164
  ), let handleReply = Self.sendReadEvent(handleEvent),
     let accountReply = Self.sendReadEvent(accountEvent),
     let handle = handleReply.stringValue,
     let resolvedAccountID = accountReply.stringValue else { return .failed }
  return .resolved(MessagesResolvedParticipant(handle: handle, accountID: resolvedAccountID))
 }

 func recheckAccount(accountID: String) -> MessagesAccountState {
  Self.readAccountState(accountID: accountID)
 }

 func submit(accountID: String, phoneE164: String, text: String) -> MessagesAppleEventSubmission {
  guard let event = MessagesAppleEventBuilder.sendEvent(accountID: accountID, phoneE164: phoneE164, text: text) else {
   return .indeterminate
  }
  switch Self.sendEvent(event, timeoutTicks: Self.sendTimeoutTicks, allowInteraction: false) {
  case .success:
   return .accepted
  case .consentRequired:
   return .consentRequired
  case .applicationError:
   return .indeterminate
  case .transportError:
   return .indeterminate
  }
 }

 private enum EventReply {
  case success(NSAppleEventDescriptor)
  case consentRequired
  case applicationError
  case transportError
 }

 private static func getEveryAccountProperty(_ propertyCode: OSType) -> NSAppleEventDescriptor? {
  guard let event = MessagesAppleEventBuilder.getEveryAccountPropertyEvent(propertyCode),
        case .success(let value) = sendEvent(event, timeoutTicks: readTimeoutTicks, allowInteraction: true) else { return nil }
  return value
 }

 private static func getAccountProperty(accountID: String, propertyCode: OSType) -> NSAppleEventDescriptor? {
  guard let event = MessagesAppleEventBuilder.getAccountPropertyEvent(accountID: accountID, propertyCode: propertyCode),
        case .success(let value) = sendEvent(event, timeoutTicks: readTimeoutTicks, allowInteraction: true) else { return nil }
  return value.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject)
 }

 // An account whose properties Messages refuses to report (application error,
 // e.g. -10000 for non-messaging accounts) cannot be the iMessage account, so it
 // is skipped. Consent or transport failures stay fatal (.failed).
 private static func readAccountState(accountID: String) -> MessagesAccountState {
  guard MessagesAppleEventSender.isValidAccountID(accountID),
        let enabledEvent = MessagesAppleEventBuilder.getAccountPropertyEvent(accountID: accountID, propertyCode: MessagesAppleEventCode.enabledProperty),
        let serviceEvent = MessagesAppleEventBuilder.getAccountPropertyEvent(accountID: accountID, propertyCode: MessagesAppleEventCode.serviceTypeProperty) else { return .failed }
  let enabledReply = sendEvent(enabledEvent, timeoutTicks: readTimeoutTicks, allowInteraction: true)
  if case .applicationError = enabledReply { return .unavailable }
  let serviceReply = sendEvent(serviceEvent, timeoutTicks: readTimeoutTicks, allowInteraction: true)
  if case .applicationError = serviceReply { return .unavailable }
  guard case .success(let enabledResponse) = enabledReply,
        case .success(let serviceResponse) = serviceReply,
        let enabled = enabledResponse.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject),
        let service = serviceResponse.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject),
        enabled.descriptorType == MessagesAppleEventCode.boolean,
        service.descriptorType == MessagesAppleEventCode.enumeration else { return .failed }
  guard enabled.booleanValue,
        service.enumCodeValue == MessagesAppleEventCode.iMessageServiceType else { return .unavailable }
  return .enabledIMessage
 }

 private static func sendReadEvent(_ event: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
  guard case .success(let value) = sendEvent(event, timeoutTicks: readTimeoutTicks, allowInteraction: true) else { return nil }
  return value.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject)
 }

 private static func sendEvent(_ event: NSAppleEventDescriptor, timeoutTicks: Int, allowInteraction: Bool) -> EventReply {
  guard let rawEvent = event.aeDesc else { return .transportError }
  var reply = AEDesc(descriptorType: MessagesAppleEventCode.null, dataHandle: nil)
  var mode = AESendMode(kAEWaitReply)
  if allowInteraction {
   mode |= AESendMode(kAECanInteract)
  } else {
   mode |= AESendMode(kAENeverInteract | kAEDoNotPromptForUserConsent)
  }
  let status = AESendMessage(rawEvent, &reply, mode, timeoutTicks)
  Self.lastEventStatus = Int32(truncatingIfNeeded: status)
  guard status == noErr else {
   _ = AEDisposeDesc(&reply)
   if status == errAEEventWouldRequireUserConsent { return .consentRequired }
   return .transportError
  }
  let response = NSAppleEventDescriptor(aeDescNoCopy: &reply)
  guard response.eventClass == MessagesAppleEventCode.replyEventClass,
        response.eventID == MessagesAppleEventCode.answerEvent else { return .transportError }
  if let error = response.paramDescriptor(forKeyword: MessagesAppleEventCode.errorNumber) {
   guard error.descriptorType == MessagesAppleEventCode.signedInt16 || error.descriptorType == MessagesAppleEventCode.signedInt32,
         error.int32Value == 0 else {
   Self.lastEventStatus = error.int32Value
   return .applicationError
  }
  }
  return .success(response)
 }

 private static func listOrScalar(_ value: NSAppleEventDescriptor) -> [NSAppleEventDescriptor]? {
  guard value.descriptorType == MessagesAppleEventCode.appleEventList else { return [value] }
  let count = value.numberOfItems
  guard count <= maximumAccounts else { return nil }
  guard count > 0 else { return [] }
  var items: [NSAppleEventDescriptor] = []
  for index in 1...count {
   guard let item = value.atIndex(index) else { return nil }
   items.append(item)
  }
  return items
 }
}
