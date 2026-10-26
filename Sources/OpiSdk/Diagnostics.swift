import Foundation

/// Normal records SDK requests, responses and operation lifecycle. Extended also records redacted protocol structure.
public enum OpiLogLevel: String, Codable, Sendable, CaseIterable {
  case normal, extended
}

/// Optional, bounded SDK diagnostics. Protocol and receipt details are logged with PAN masking and sensitive authentication data removed.
/// File work runs on a separate queue so callback acknowledgements do not wait for logging.
public final class OpiDiagnostics: Sendable {
  private static let queue = DispatchQueue(label: "io.github.richiehug.opi.diagnostics", qos: .utility)
  private static var url: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpiSdk", isDirectory: true).appendingPathComponent("diagnostics.log")
  }
  private let options: OpiOptions
  private let enabled: Bool
  private let level: OpiLogLevel
  private let limit: Int

  init(options: OpiOptions) {
    self.options = options
    enabled = options.loggingEnabled
    level = options.logLevel
    limit = options.maxLogStorageBytes
  }

  func event(operation: OpiOperation, correlationId: String, stage: String, code: String? = nil) {
    guard enabled else { return }
    // Correlation IDs are SDK-generated UUIDs. Unrecognized external identifiers stay private.
    let id = UUID(uuidString: correlationId)?.uuidString ?? "[redacted]"
    let safeStage = OperationEvent.Kind(rawValue: stage)?.rawValue ?? "operation"
    Self.queue.async {
      Self.append(limit: self.limit, "\(operation.rawValue) \(id) \(safeStage)")
    }
    if let code { sdkError(code: code) }
  }

  static func method(_ operation: OpiOperation) -> String {
    switch operation {
    case .payment: "OpiClient.payment(_: PaymentRequest)"
    case .refund: "OpiClient.refund(_: PaymentRequest, authReference: String?)"
    default: "OpiClient.\(operation.rawValue)()"
    }
  }

  func request(_ pending: Pending) {
    guard enabled else { return }
    let id = UUID(uuidString: pending.correlationId)?.uuidString ?? "[redacted]"
    let amount = pending.amount.map(String.init) ?? "none"
    let currency = Self.safeCode(pending.currency)
    let fields: [(String, String)] = [
      ("method", pending.diagnosticMethod ?? Self.method(pending.operation)),
      ("correlationId", id), ("requestId", Self.safeCode(pending.requestId)),
      ("request.operation", pending.operation.rawValue),
      ("request.amount", amount), ("request.currency", currency),
      ("request.reference", pending.reference.map(Self.safeCode) ?? "not supplied"),
      ("request.authReference", pending.authReferenceProvided ? "supplied (see extended XML)" : "not supplied"),
      ("options.terminalHost", options.terminalHost),
      ("options.workstationId", Self.safeCode(options.workstationId)),
      ("options.payChannelPort", String(options.payChannelPort)),
      ("options.deviceChannelPort", String(options.deviceChannelPort)),
      ("options.language", options.language),
      ("options.forceAcceptance", String(options.forceAcceptance)),
      ("options.requestFullPan", options.requestFullPan.map(String.init) ?? "not specified"),
      ("options.receipts.merchantReceipt", options.receipts.merchantReceipt.rawValue),
      ("options.receipts.customerReceipt", options.receipts.customerReceipt.rawValue),
      ("options.connectTimeout", String(options.connectTimeout)),
      ("options.operationTimeout", String(options.operationTimeout)),
    ]
    let details = fields.map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
    Self.queue.async {
      Self.append(limit: self.limit, "request \(pending.operation.rawValue) \(id) amount=\(amount) currency=\(currency) minor units\n\(details)")
    }
  }

  func response(operation: OpiOperation, result: OpiResult, method: String? = nil) {
    guard enabled else { return }
    let id = UUID(uuidString: result.correlationId)?.uuidString ?? "[redacted]"
    let amount = result.transaction?.amount.map(String.init) ?? "none"
    let currency = Self.safeCode(result.transaction?.currency)
    let code = Self.safeCode(result.errorCode)
    let transport = Self.safeCode(result.transportErrorCode)
    var fields: [(String, String)] = [
      ("method", method ?? Self.method(operation)), ("correlationId", id),
      ("result.status", result.status.rawValue),
      ("result.errorCode", code), ("result.transportErrorCode", transport),
      ("result.transaction.amount", amount), ("result.transaction.currency", currency),
      ("result.transaction.reference", Self.safeCode(result.transaction?.reference)),
      ("result.transaction.authReference", Self.safeCode(result.transaction?.authReference)),
      ("result.transaction.approvalCode", Self.safeCode(result.transaction?.approvalCode)),
      ("result.transaction.tip", result.transaction?.tip.map(String.init) ?? "none"),
      ("result.transaction.paymentMethod", Self.safeCode(result.transaction?.paymentMethod)),
      ("result.transaction.receipts.merchantReceipt", result.transaction?.receipts?.merchantReceipt == nil ? "not returned" : "returned (content omitted)"),
      ("result.transaction.receipts.customerReceipt", result.transaction?.receipts?.customerReceipt == nil ? "not returned" : "returned (content omitted)"),
    ]
    if let count = result.transaction?.receipts?.serviceReceipts?.count, count > 1 {
      fields.append(("result.transaction.receipts.serviceReceipts", "\(count) received (content omitted)"))
    }
    let details = fields.map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
    Self.queue.async {
      Self.append(limit: self.limit, "response \(operation.rawValue) \(id) status=\(result.status.rawValue) amount=\(amount) currency=\(currency) minor units errorCode=\(code) transportError=\(transport)\n\(details)")
    }
  }

  private static func safeCode(_ value: String?) -> String {
    guard let value else { return "none" }
    guard value.count <= 80, value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return "[redacted]" }
    return value
  }

  func communication(direction: String, xml: String) {
    guard enabled, level == .extended else { return }
    let direction = ["sent", "received", "callback", "ack"].contains(direction) ? direction : "protocol"
    Self.queue.async { Self.append(limit: self.limit, "\(direction) \(Self.redactedXML(xml))") }
  }

  func sdkError(code: String) {
    guard enabled, level == .extended else { return }
    let known = ["RESULT_UNKNOWN", "CONNECTION_ERROR", "CONNECTION_LOST", "OPERATION_TIMEOUT",
      "ABORT_UNAVAILABLE", "ABORT_TIMEOUT", "INVALID_OPI_RESPONSE",
      "APPLICATION_BACKGROUNDED", "BACKGROUND", "BACKGROUND_EXPIRED"]
    let safe = known.contains(code) ? code : "SDK_OR_TERMINAL_ERROR"
    Self.queue.async { Self.append(limit: self.limit, "error \(safe)") }
  }

  /// Read captured diagnostics, including entries queued before this call.
  public static func read() async -> String {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
      }
    }
  }

  /// Delete captured SDK diagnostics. Does not change transaction history or terminal state.
  public static func clear() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private static func append(limit: Int, _ line: String) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let entry = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
      var data = (try? Data(contentsOf: url)) ?? Data()
      data.append(Data(entry.utf8))
      data = retained(data, limit: limit)
      try data.write(to: url, options: .atomic)
    } catch {
      // Optional diagnostics must never change an operation's result.
    }
  }

  /// Keep only complete UTF-8 entries within the configured byte budget.
  static func retained(_ input: Data, limit: Int) -> Data {
    guard limit > 0 else { return Data() }
    guard input.count > limit else { return input }
    let tail = Data(input.suffix(limit))
    var start = tail.startIndex
    while let newline = tail[start...].firstIndex(of: 10) {
      start = tail.index(after: newline)
      let prefix = String(decoding: tail[start...].prefix(20), as: UTF8.self)
      if prefix.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T", options: .regularExpression) != nil {
        return Data(tail.suffix(from: start))
      }
    }
    return Data()
  }

  static func redactedXML(_ xml: String) -> String {
    guard (try? parseXML(xml)) != nil else { return "[invalid XML omitted]" }
    return DiagnosticSanitizer.xml(xml)
  }
}
