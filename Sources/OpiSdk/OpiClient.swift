import Darwin
import Foundation

/// Retain one client per terminal. Observe events independently and await each final command result.
public actor OpiClient {
  /// Observe operation lifecycle, receipt, DCC and recovery events in a retained task. Dispatch UI changes to MainActor without blocking networking.
  public nonisolated let events: AsyncStream<OperationEvent>
  private let stream: AsyncStream<OperationEvent>.Continuation
  private let options: OpiOptions
  private let diagnostics: OpiDiagnostics
  private var occupied = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var disposed = false
  private var active: Pending?
  private var activeTransport: TCPExchange?
  private var abortTransport: TCPExchange?
  private var abortTask: Task<OpiResult, Never>?
  private var abortAttempts = 0
  private var lastAbort = Date.distantPast
  private var requestId = Int(Date().timeIntervalSince1970) % 2_147_483_646
  /// Create one retained client per terminal with a stable workstation identity.
  public init(options: OpiOptions) throws {
    try options.validate()
    self.options = options
    diagnostics = OpiDiagnostics(options: options)
    // The callback peer is verified against the configured numeric address.
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    guard
      inet_pton(AF_INET, options.terminalHost, &ipv4) == 1
        || inet_pton(AF_INET6, options.terminalHost, &ipv6) == 1
    else { throw OpiSdkError.invalidOptions }
    let pair = AsyncStream<OperationEvent>.makeStream()
    events = pair.stream
    stream = pair.continuation
  }
  deinit {
    stream.finish()
  }
  private func enter() async throws {
    if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
    if disposed {
      leave()
      throw OpiSdkError.disposed
    }
  }
  private func leave() {
    if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
  }
  private func pending(_ op: OpiOperation, _ r: PaymentRequest? = nil) -> Pending {
    requestId = requestId >= 2_147_483_646 ? 1 : requestId + 1
    return Pending(
      operation: op, correlationId: UUID().uuidString, requestId: String(requestId),
      amount: r?.amount, currency: r?.currency, reference: r?.reference)
  }
  private func emit(_ p: Pending, _ kind: OperationEvent.Kind, _ result: OpiResult? = nil) {
    diagnostics.event(operation: p.operation, correlationId: p.correlationId,
      stage: kind.rawValue, code: result?.errorCode)
    stream.yield(
      OperationEvent(
        operation: p.operation, correlationId: p.correlationId, kind: kind, result: result))
  }
  private func fail(_ p: Pending, _ state: ResultState, _ code: String) -> OpiResult {
    OpiResult(status: state, correlationId: p.correlationId, errorCode: code)
  }
  private func exchange(
    _ p: Pending, auth: String? = nil, wire: Pending? = nil, control: Bool = false
  ) async throws -> Exchange {
    let stream = self.stream
    let t = TCPExchange(options, p, try buildRequest(options, wire ?? p, auth), control: control,
      diagnostics: diagnostics) {
      event in stream.yield(event)
    }
    if control { abortTransport = t } else { activeTransport = t }
    defer { if control { abortTransport = nil } else { activeTransport = nil } }
    let background = p.operation.financial && !control
      ? await OperationBackgroundTask(expiration: { t.cancel() }) : nil
    do {
      let result = try await t.run()
      let expired = await background?.finish() ?? false
      if expired { throw TransportError(sent: true, reason: "BACKGROUND_EXPIRED") }
      return result
    } catch {
      let expired = await background?.finish() ?? false
      if expired { throw TransportError(sent: true, reason: "BACKGROUND_EXPIRED") }
      throw error
    }
  }
  private func validated(_ r: PaymentRequest) throws -> PaymentRequest {
    var r = r
    r.currency = r.currency.uppercased()
    guard r.amount > 0 else { throw OpiSdkError.invalidRequest }
    _ = try currencyDigits(r.currency)
    if let ref = r.reference,
      ref.range(of: "^[A-Za-z0-9_-]{1,20}$", options: .regularExpression) == nil
    {
      throw OpiSdkError.invalidRequest
    }
    return r
  }
  /// Take a payment using a positive amount in currency minor units. Inspect the returned status; an uncertain outcome must be reconciled before retrying.
  public func payment(_ request: PaymentRequest) async throws -> OpiResult {
    let r = try validated(request)
    if occupied { return fail(pending(.payment), .invalidRequest, "PENDING_TRANSACTION") }
    try await enter()
    defer { leave() }
    return try await financial(pending(.payment, r))
  }
  /// Refund a positive amount in currency minor units. An optional authorization reference identifies the original terminal transaction when required.
  public func refund(_ request: PaymentRequest, authReference: String? = nil) async throws
    -> OpiResult
  {
    let r = try validated(request)
    if let authReference,
      authReference.range(of: "^[A-Za-z0-9_-]{1,20}$", options: .regularExpression) == nil
    {
      throw OpiSdkError.invalidRequest
    }
    if occupied { return fail(pending(.refund), .invalidRequest, "PENDING_TRANSACTION") }
    try await enter()
    defer { leave() }
    return try await financial(pending(.refund, r), authReference)
  }
  /// Reverse the last eligible terminal transaction. This operation does not accept an arbitrary historical transaction reference.
  public func reversal() async throws -> OpiResult {
    if occupied { return fail(pending(.reversal), .invalidRequest, "PENDING_TRANSACTION") }
    try await enter()
    defer { leave() }
    return try await financial(pending(.reversal))
  }
  private func financial(_ p: Pending, _ auth: String? = nil) async throws -> OpiResult {
    active = [.payment, .refund].contains(p.operation) ? p : nil
    abortAttempts = 0
    lastAbort = .distantPast
    emit(p, .started)
    var r: OpiResult
    do {
      let x = try await exchange(p, auth: auth)
      r = try parseResult(x.xml, p, x.capture)
      if [.unknown, .communicationError, .inProgress].contains(r.status) {
        r = fail(p, .unknown, "RESULT_UNKNOWN")
      }
    } catch let e as TransportError {
      r = fail(p, e.sent ? .unknown : .communicationError,
        e.sent ? "RESULT_UNKNOWN" : "CONNECTION_ERROR")
      r.transportErrorCode = e.reason
    } catch { r = fail(p, .unknown, "RESULT_UNKNOWN") }
    active = nil
    // A final financial outcome must not wait minutes for an unrelated missing abort ACK.
    abortTransport?.cancel()
    if let task = abortTask { _ = await task.value }
    emit(p, .completed, r)
    return r
  }
  /// Request the terminal's last message. The ECR correlates the result with its own records.
  public func repeatLastMessage() async throws -> OpiResult {
    if occupied { return fail(pending(.repeatLastMessage), .invalidRequest, "PENDING_TRANSACTION") }
    try await enter()
    defer { leave() }
    return try await service(.repeatLastMessage)
  }
  private func service(_ operation: OpiOperation) async throws -> OpiResult {
    let p = pending(operation)
    emit(p, .started)
    var r: OpiResult
    do {
      let x = try await exchange(p)
      if operation == .repeatLastMessage {
        let root = try parseXML(x.xml)
        if root.attrs["OverallResult"] == "Success" {
          if let h = root.first("OriginalHeader"),
            let original = OpiOperation.allCases.first(where: {
              $0.financial && $0.requestType == h.attrs["RequestType"]
            }), let code = h.attrs["OverallResult"]
          {
            var prior = p
            prior.operation = original
            r = try parseResult(x.xml, prior, x.capture, code)
          } else {
            r = fail(p, .unknown, "NO_ORIGINAL_FINANCIAL_RESULT")
          }
        } else {
          r = try parseResult(x.xml, p, x.capture)
        }
      } else {
        r = try parseResult(x.xml, p, x.capture)
      }
    } catch let e as TransportError {
      r = fail(p, .communicationError, e.sent ? e.reason : "CONNECTION_ERROR")
      r.transportErrorCode = e.reason
    } catch { r = fail(p, .terminalError, "INVALID_OPI_RESPONSE") }
    emit(p, .completed, r)
    return r
  }
  /// Acknowledgement of an abort request is not the final financial outcome. Keep awaiting payment/refund.
  /// Send AbortRequest on a separate connection during an active payment or refund. Enable the application abort control after the connected event. An acknowledgement is not the final financial outcome: keep awaiting payment or refund.
  public func abort() async throws -> OpiResult {
    if let task = abortTask { return await task.value }
    let p = pending(.abort)
    guard let operation = active, let transport = activeTransport,
      await transport.hasSent(), active?.correlationId == operation.correlationId
    else { return fail(p, .invalidRequest, "NO_ACTIVE_OPERATION") }
    guard abortAttempts < options.maxAbortAttempts else {
      return fail(p, .invalidRequest, "ABORT_LIMIT_REACHED")
    }
    guard Date().timeIntervalSince(lastAbort) >= options.abortRetryDelay else {
      return fail(p, .invalidRequest, "ABORT_RETRY_DELAY")
    }
    abortAttempts += 1
    lastAbort = Date()
    let task = Task {
      guard self.active?.correlationId == operation.correlationId else {
        return self.fail(p, .invalidRequest, "NO_ACTIVE_OPERATION")
      }
      self.emit(p, .started)
      var r: OpiResult
      do {
        let x = try await self.exchange(p, control: true)
        r = try parseResult(x.xml, p, x.capture)
      } catch let e as TransportError {
        r = self.fail(p, .communicationError, "ABORT_UNAVAILABLE")
        r.transportErrorCode = e.reason
      } catch { r = self.fail(p, .communicationError, "ABORT_UNAVAILABLE") }
      self.emit(p, .completed, r)
      return r
    }
    abortTask = task
    defer { abortTask = nil }
    return await task.value
  }
  /// Execute a service operation. Use the dedicated transaction and recovery methods for financial operations, abort and RepeatLastMessage.
  public func perform(_ operation: OpiOperation) async throws -> OpiResult {
    guard !operation.financial, operation != .abort, operation != .repeatLastMessage else {
      throw OpiSdkError.invalidRequest
    }
    if occupied { return fail(pending(operation), .invalidRequest, "PENDING_TRANSACTION") }
    try await enter()
    defer { leave() }
    return try await service(operation)
  }
  /// Request the last receipt using TicketReprint. Receipt evidence and RepeatLastMessage serve different purposes; correlate the returned receipt with the original transaction.
  public func reprint() async throws -> OpiResult { try await perform(.reprint) }
  /// Request GetInfo terminal information. A terminal may reject this operation even when GetStatus succeeds; that error is preserved.
  public func info() async throws -> OpiResult { try await perform(.info) }
  /// Request GetStatus to retrieve the current terminal state.
  public func status() async throws -> OpiResult { try await perform(.status) }
  /// Activate the terminal for transaction processing.
  public func activate() async throws -> OpiResult { try await perform(.activate) }
  /// Deactivate terminal transaction processing.
  public func deactivate() async throws -> OpiResult { try await perform(.deactivate) }
  /// Log in the workstation at the terminal.
  public func login() async throws -> OpiResult { try await perform(.login) }
  /// Log off the workstation at the terminal.
  public func logoff() async throws -> OpiResult { try await perform(.logoff) }
  /// Request TransmitTrx to transmit stored terminal transactions.
  public func submit() async throws -> OpiResult { try await perform(.submit) }
  /// Request CloseDay. This closes the terminal day; it does not release the client.
  public func close() async throws -> OpiResult { try await perform(.close) }
  /// Request ContactTMS to refresh terminal configuration.
  public func config() async throws -> OpiResult { try await perform(.config) }
  /// Request ContactAcq to initialize the terminal with its acquirer.
  public func initialize() async throws -> OpiResult { try await perform(.initialize) }
  /// Request RestartTerminal. Do not call during an active financial operation.
  public func reset() async throws -> OpiResult { try await perform(.reset) }
  /// Release the client after operations finish. This is not an abort request.
  public func dispose() async throws {
    try await enter()
    defer { leave() }
    if let task = abortTask { _ = await task.value }
    disposed = true
    stream.finish()
  }
}
