import Foundation

/// Normal records operation lifecycle. Extended also records redacted protocol structure.
public enum OpiLogLevel: String, Codable, Sendable, CaseIterable {
  case normal, extended
}

/// Optional, bounded SDK diagnostics. Receipt text, card data and tokens are never logged.
/// File work runs on a separate queue so callback acknowledgements do not wait for logging.
public final class OpiDiagnostics: Sendable {
  private static let queue = DispatchQueue(label: "io.github.richiehug.opi.diagnostics", qos: .utility)
  private static let limit = 512 * 1024
  private static var url: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpiSdk", isDirectory: true).appendingPathComponent("diagnostics.log")
  }
  private let enabled: Bool
  private let level: OpiLogLevel

  init(options: OpiOptions) {
    enabled = options.loggingEnabled
    level = options.logLevel
  }

  func event(operation: OpiOperation, correlationId: String, stage: String, code: String? = nil) {
    guard enabled else { return }
    // Correlation IDs are SDK-generated UUIDs. Unrecognized external identifiers stay private.
    let id = UUID(uuidString: correlationId)?.uuidString ?? "[redacted]"
    let safeStage = OperationEvent.Kind(rawValue: stage)?.rawValue ?? "operation"
    Self.queue.async {
      Self.append("\(operation.rawValue) \(id) \(safeStage)")
    }
    if let code { sdkError(code: code) }
  }

  func communication(direction: String, xml: String) {
    guard enabled, level == .extended else { return }
    let direction = ["sent", "received", "callback", "ack"].contains(direction) ? direction : "protocol"
    Self.queue.async { Self.append("\(direction) \(Self.redactedXML(xml))") }
  }

  func sdkError(code: String) {
    guard enabled, level == .extended else { return }
    let known = ["RESULT_UNKNOWN", "CONNECTION_ERROR", "CONNECTION_LOST", "OPERATION_TIMEOUT",
      "ABORT_UNAVAILABLE", "ABORT_TIMEOUT", "INVALID_OPI_RESPONSE",
      "APPLICATION_BACKGROUNDED", "BACKGROUND", "BACKGROUND_EXPIRED"]
    let safe = known.contains(code) ? code : "SDK_OR_TERMINAL_ERROR"
    Self.queue.async { Self.append("error \(safe)") }
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

  private static func append(_ line: String) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let entry = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
      var data = (try? Data(contentsOf: url)) ?? Data()
      data.append(Data(entry.utf8))
      if data.count > limit {
        data = Data(data.suffix(limit))
        if let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
      }
      try data.write(to: url, options: .atomic)
    } catch {
      // Optional diagnostics must never change an operation's result.
    }
  }

  static func redactedXML(_ xml: String) -> String {
    guard let root = try? parseXML(xml) else { return "[invalid XML omitted]" }
    let safeAttributes: [String: Set<String>] = [
      "RequestType": Set(OpiOperation.allCases.map(\.requestType) + ["Output", "Input"]),
      "OverallResult": ["Success", "Failure", "Aborted", "Declined", "Partial", "DeviceUnavailable"],
      "OutDeviceTarget": ["Printer", "JournalPrinter", "CashierDisplay", "CustomerDisplay", "E-Journal"],
      "InDeviceTarget": ["CashierKeyboard", "CustomerKeyboard"],
      "TicketType": ["Merchant", "Customer", "MerchantReceipt", "CustomerReceipt"],
    ]
    let safeText: [String: Set<String>] = [
      "PrinterStatus": ["Available", "PrintLocal"], "JournalPrinterStatus": ["Available", "PrintLocal"],
      "E-JournalStatus": ["Available", "Unavailable"], "Command": ["GetConfirmation"],
    ]
    func render(_ node: XMLNode) -> String {
      let attributes = node.attrs.sorted { $0.key < $1.key }.map { name, value in
        " \(name)=\"\(safeAttributes[name]?.contains(value) == true ? escaped(value) : "[redacted]")\""
      }.joined()
      let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = value.isEmpty ? "" : safeText[node.name]?.contains(value) == true ? escaped(value) : "[redacted]"
      return "<\(node.name)\(attributes)>\(text)\(node.children.map(render).joined())</\(node.name)>"
    }
    return render(root)
  }
}
