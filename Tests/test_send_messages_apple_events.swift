import Foundation

final class MockMessagesTransport: MessagesAppleEventTransport {
 var accountLookup: MessagesAccountLookup = .accountIDs([])
 var participantLookup: MessagesParticipantLookup = .failed
 var accountState: MessagesAccountState = .enabledIMessage
 var submission: MessagesAppleEventSubmission = .accepted
 var operations: [String] = []
 var submittedAccountID: String?
 var submittedPhone: String?
 var submittedText: String?
 var submissionCount = 0

 func enabledIMessageAccountIDs() -> MessagesAccountLookup {
  operations.append("accounts")
  return accountLookup
 }

 func resolveParticipant(accountID: String, phoneE164: String) -> MessagesParticipantLookup {
  operations.append("resolve")
  return participantLookup
 }

 func recheckAccount(accountID: String) -> MessagesAccountState {
  operations.append("recheck")
  return accountState
 }

 func submit(accountID: String, phoneE164: String, text: String) -> MessagesAppleEventSubmission {
  operations.append("submit")
  submissionCount += 1
  submittedAccountID = accountID
  submittedPhone = phoneE164
  submittedText = text
  return submission
 }
}

@main
struct TestMessagesAppleEvents {
 static let phone = "+15555550123"
 static let accountID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

 static func main() {
  testValidationAndNoAttempt()
  testUniqueAccountAndParameterizedPayload()
  testZeroOrMultipleAccountsFailClosed()
  testTargetReadbackMustMatchByteForByte()
  testRecheckAndDispatchGate()
  testTimeoutIsIndeterminateAndNeverRetried()
  testAppleEventDescriptorConstruction()
  print("PASS synthetic Apple Events sender gates, target binding, bounded inputs, and single-attempt status")
 }

 static func sender(_ transport: MockMessagesTransport) -> MessagesAppleEventSender {
  MessagesAppleEventSender(transport: transport)
 }

 static func configuredTransport() -> MockMessagesTransport {
  let transport = MockMessagesTransport()
  transport.accountLookup = .accountIDs([accountID])
  transport.participantLookup = .resolved(MessagesResolvedParticipant(handle: phone, accountID: accountID))
  return transport
 }

 static func testValidationAndNoAttempt() {
  let transport = configuredTransport()
  let api = sender(transport)
  let invalidPhone = api.send(phoneE164: "+1 5555550123", text: "sample", canDispatch: { true })
  precondition(invalidPhone == .notAttempted(.invalidRecipient))
  precondition(transport.operations.isEmpty)

  let emptyText = api.send(phoneE164: phone, text: "", canDispatch: { true })
  precondition(emptyText == .notAttempted(.invalidText))
  precondition(transport.operations.isEmpty)

  let nulText = api.send(phoneE164: phone, text: "a\0b", canDispatch: { true })
  precondition(nulText == .notAttempted(.invalidText))
  precondition(transport.operations.isEmpty)

  let overlongText = api.send(phoneE164: phone, text: String(repeating: "x", count: 4_097), canDispatch: { true })
  precondition(overlongText == .notAttempted(.invalidText))
  precondition(transport.operations.isEmpty)
 }

 static func testUniqueAccountAndParameterizedPayload() {
  let transport = configuredTransport()
  let api = sender(transport)
  let literal = "Quote: \";\nend tell\nsend \"other\" to every participant — привет 👋"
  var gateCalls = 0
  let result = api.send(phoneE164: phone, text: literal, canDispatch: {
   gateCalls += 1
   transport.operations.append("gate")
   return true
  })
  precondition(result == .accepted)
  precondition(gateCalls == 1)
  precondition(transport.submissionCount == 1)
  precondition(transport.submittedAccountID == accountID)
  precondition(transport.submittedPhone == phone)
  precondition(transport.submittedText == literal)
  precondition(transport.operations == ["accounts", "resolve", "recheck", "gate", "submit"])
 }

 static func testZeroOrMultipleAccountsFailClosed() {
  for ids in [[], [accountID, "other-account"]] {
   let transport = configuredTransport()
   transport.accountLookup = .accountIDs(ids)
   let result = sender(transport).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
   precondition(result == .notAttempted(.noUniqueEnabledIMessageAccount))
   precondition(transport.operations == ["accounts"])
   precondition(transport.submissionCount == 0)
  }

  let failed = configuredTransport()
  failed.accountLookup = .failed
  let failedResult = sender(failed).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
  precondition(failedResult == .notAttempted(.accountLookupFailed))
  precondition(failed.operations == ["accounts"])
 }

 static func testTargetReadbackMustMatchByteForByte() {
  let handleMismatch = configuredTransport()
  handleMismatch.participantLookup = .resolved(MessagesResolvedParticipant(handle: "+15555550124", accountID: accountID))
  let handleResult = sender(handleMismatch).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
  precondition(handleResult == .notAttempted(.participantMismatch))
  precondition(handleMismatch.operations == ["accounts", "resolve"])
  precondition(handleMismatch.submissionCount == 0)

  let accented = configuredTransport()
  accented.accountLookup = .accountIDs(["café-account"])
  accented.participantLookup = .resolved(MessagesResolvedParticipant(handle: phone, accountID: "cafe\u{301}-account"))
  let accountResult = sender(accented).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
  precondition(accountResult == .notAttempted(.participantMismatch))
  precondition(accented.operations == ["accounts", "resolve"])
  precondition(accented.submissionCount == 0)
 }

 static func testRecheckAndDispatchGate() {
  let unavailable = configuredTransport()
  unavailable.accountState = .unavailable
  let unavailableResult = sender(unavailable).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
  precondition(unavailableResult == .notAttempted(.accountChangedBeforeSend))
  precondition(unavailable.operations == ["accounts", "resolve", "recheck"])
  precondition(unavailable.submissionCount == 0)

  let gateClosed = configuredTransport()
  let gateResult = sender(gateClosed).send(phoneE164: phone, text: "synthetic", canDispatch: {
   gateClosed.operations.append("gate")
   return false
  })
  precondition(gateResult == .notAttempted(.dispatchAuthorizationRevoked))
  precondition(gateClosed.operations == ["accounts", "resolve", "recheck", "gate"])
  precondition(gateClosed.submissionCount == 0)
 }

 static func testTimeoutIsIndeterminateAndNeverRetried() {
  let transport = configuredTransport()
  transport.submission = .indeterminate
  let result = sender(transport).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
  precondition(result == .indeterminate(.timeoutOrAppleEventFailure))
  precondition(transport.submissionCount == 1)

  let consent = configuredTransport()
  consent.submission = .consentRequired
  let consentResult = sender(consent).send(phoneE164: phone, text: "synthetic", canDispatch: { true })
  precondition(consentResult == .notAttempted(.automationConsentRequired))
  precondition(consent.submissionCount == 1)
 }

 static func testAppleEventDescriptorConstruction() {
  let literal = "first line\n\\\"; send text to every participant"
  guard let event = MessagesAppleEventBuilder.sendEvent(accountID: accountID, phoneE164: phone, text: literal),
        let body = event.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject),
        let target = event.paramDescriptor(forKeyword: MessagesAppleEventCode.toParameter),
        let account = target.forKeyword(MessagesAppleEventCode.container),
        let participantKey = target.forKeyword(MessagesAppleEventCode.keyData),
        let accountKey = account.forKeyword(MessagesAppleEventCode.keyData) else {
   preconditionFailure("synthetic send event was not fully constructed")
  }
  precondition(event.eventClass == MessagesAppleEventCode.messagesSuite)
  precondition(event.eventID == MessagesAppleEventCode.sendCommand)
  precondition(body.stringValue == literal)
  precondition(target.descriptorType == MessagesAppleEventCode.objectSpecifier)
  precondition(participantKey.stringValue == accountID + ":" + phone)
  precondition(account.descriptorType == MessagesAppleEventCode.objectSpecifier)
  precondition(accountKey.stringValue == accountID)

  guard let lookup = MessagesAppleEventBuilder.getAccountPropertyEvent(
   accountID: accountID, propertyCode: MessagesAppleEventCode.enabledProperty
  ), let property = lookup.paramDescriptor(forKeyword: MessagesAppleEventCode.directObject),
     let owner = property.forKeyword(MessagesAppleEventCode.container),
     let ownerKey = owner.forKeyword(MessagesAppleEventCode.keyData) else {
   preconditionFailure("synthetic account preflight event was not constructed")
  }
  precondition(lookup.eventClass == MessagesAppleEventCode.coreSuite)
  precondition(lookup.eventID == MessagesAppleEventCode.getDataCommand)
  precondition(ownerKey.stringValue == accountID)
 }
}
