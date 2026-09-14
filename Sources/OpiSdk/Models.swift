import Foundation

/// Supported OPI transaction and terminal operation names.
public enum OpiOperation: String, Codable, Sendable, CaseIterable {
  case payment, refund, reversal, abort, reprint, repeatLastMessage, activate, deactivate, info,
    status, submit, close, config, initialize, reset, login, logoff
  var financial: Bool { [.payment, .refund, .reversal].contains(self) }
  var requestType: String {
    switch self {
    case .payment: "CardPayment"
    case .refund: "PaymentRefund"
    case .reversal: "PaymentReversal"
    case .abort: "AbortRequest"
    case .reprint: "TicketReprint"
    case .repeatLastMessage: "RepeatLastMessage"
    case .activate: "ActivateTerminal"
    case .deactivate: "DeactivateTerminal"
    case .info: "GetInfo"
    case .status: "GetStatus"
    case .submit: "TransmitTrx"
    case .close: "CloseDay"
    case .config: "ContactTMS"
    case .initialize: "ContactAcq"
    case .reset: "RestartTerminal"
    case .login: "Login"
    case .logoff: "Logoff"
    }
  }
}
/// Operation outcomes. Success is confirmed approval; Declined is a decline; Aborted is cancellation. Unknown/InProgress require reconciliation rather than an automatic new payment.
public enum ResultState: String, Codable, Sendable {
  case success, declined, aborted, communicationError, terminalError, invalidRequest, inProgress,
    unknown
}
/// Available returns receipt data, PrintLocal requests terminal printing.
public enum ReceiptHandlingMode: String, Codable, Sendable {
  case available = "Available"
  case printLocal = "PrintLocal"
}
/// Independent receipt handling for merchant and customer copies; both default to Available.
public struct ReceiptHandling: Sendable {
  /// Merchant receipt copy or handling mode. Available returns text; PrintLocal requests terminal printing.
  public var merchantReceipt: ReceiptHandlingMode
  /// Customer receipt copy or handling mode. Available returns text; PrintLocal requests terminal printing.
  public var customerReceipt: ReceiptHandlingMode
  /// Create a value using the supplied arguments.
  public init(
    merchantReceipt: ReceiptHandlingMode = .available,
    customerReceipt: ReceiptHandlingMode = .available
  ) {
    self.merchantReceipt = merchantReceipt
    self.customerReceipt = customerReceipt
  }
}
/// Positive payment/refund amount in currency minor units, currency and optional reference.
public struct PaymentRequest: Sendable {
  /// Positive amount in currency minor units; CHF 12.50 is 1250.
  public var amount: Int64
  /// ISO 4217 currency code, for example CHF.
  public var currency: String
  /// Optional application or terminal transaction reference.
  public var reference: String?
  /// Create a value using the supplied arguments.
  public init(amount: Int64, currency: String, reference: String? = nil) {
    self.amount = amount
    self.currency = currency
    self.reference = reference
  }
}
/// Receipt copy returned to the application.
public struct Receipt: Codable, Sendable {
  /// Receipt text. Preserve whitespace and use a monospace font when displaying or printing.
  public let content: String
  /// Receipt media type: text/plain.
  public let contentType: String
  init(_ text: String) {
    content = text
    contentType = "text/plain"
  }
}
/// Separate merchant and customer receipt copies.
public struct ReceiptDetails: Codable, Sendable {
  /// Merchant receipt copy or handling mode. Available returns text; PrintLocal requests terminal printing.
  public var merchantReceipt: Receipt?
  /// Customer receipt copy or handling mode. Available returns text; PrintLocal requests terminal printing.
  public var customerReceipt: Receipt?
}
/// Dynamic Currency Conversion offer/result details when returned by the terminal.
public struct DccDetails: Codable, Sendable {
  /// Whether a DCC offer was observed.
  public var offered = true
  /// Whether acceptance is established from returned DCC data and the observed offer.
  public var accepted = true
  /// Terminal-provided DCC amount as decimal text.
  public var amount: String?
  /// ISO 4217 currency code, for example CHF.
  public var currency: String?
  /// Terminal-provided currency code for DCC.
  public var currencyCode: String?
  /// Terminal-provided DCC exchange rate as text.
  public var exchangeRate: String?
  /// Terminal-provided DCC markup percentage as text.
  public var markupPercentage: String?
}
/// Terminal-supplied financial, card, receipt and DCC details.
public struct TransactionResult: Codable, Sendable {
  /// Optional application or terminal transaction reference.
  public var reference: String?
  /// Terminal-supplied amount in currency minor units.
  public var amount: Int64?
  /// ISO 4217 currency code, for example CHF.
  public var currency: String?
  /// Tip in currency minor units when supplied.
  public var tip: Int64?
  /// Normalized lowercase brand; unknown values are trimmed and lowercased.
  public var paymentMethod: String?
  /// Masked card number when supplied by the terminal.
  public var maskedCardNumber: String?
  /// Terminal authorization/transaction reference; not the application correlation ID.
  public var authReference: String?
  /// Authorization approval code supplied by the terminal.
  public var approvalCode: String?
  /// Terminal-supplied transaction timestamp.
  public var transactionDate: String?
  /// Acquirer identifier supplied by the terminal.
  public var acquirerId: String?
  /// Merchant and customer receipt copies. Options default to Available for both; results may omit copies not supplied by the terminal.
  public var receipts: ReceiptDetails?
  /// Dynamic Currency Conversion information when supplied.
  public var dcc: DccDetails?
}
/// Structured outcome of a terminal operation. Optional fields are populated only when supplied.
public struct OpiResult: Codable, Sendable {
  /// Structured operation outcome. Unknown is unresolved, not a decline; reconcile before retrying.
  public var status: ResultState
  /// SDK tracking identifier linking events and results for the same logical operation.
  public var correlationId: String
  /// Terminal or SDK error code when available. Preserve it for diagnosis and reconciliation.
  public var errorCode: String?
  /// Transport diagnostic when communication failed. RESULT_UNKNOWN remains the financial error code after transmission.
  public var transportErrorCode: String?
  /// Financial details when provided by the terminal.
  public var transaction: TransactionResult?
  /// Terminal information/status fields when supplied.
  public var terminal: [String: String]?
  /// True only for a Success outcome.
  public var isSuccessful: Bool { status == .success }
}
/// Lifecycle and terminal data for one correlated operation.
public struct OperationEvent: Sendable {
  public enum Kind: String, Sendable {
    case started, connected, terminalMessage, receiptCaptured, dccCaptured, recoveryStarted,
      recoveryCompleted, transactionRecovered, completed
  }
  /// The logical operation associated with this event.
  public let operation: OpiOperation
  /// SDK tracking identifier linking events and results for the same logical operation.
  public let correlationId: String
  /// Event lifecycle stage; connected enables abort, recoveryStarted disables it, completed supplies the outcome.
  public let kind: Kind
  /// Terminal display text when supplied. The application chooses whether and where to show it.
  public var message: String?
  /// Captured receipt copy.
  public var receipt: Receipt?
  /// Identifies the merchant or customer receipt.
  public var receiptType: String?
  /// Completed or recovered result. Update the original transaction identified by correlationId.
  public var result: OpiResult?
}
/// Connection, protocol, receipt and recovery configuration for one terminal.
public struct OpiOptions: Sendable {
  /// Numeric IPv4 or IPv6 terminal address. Configure explicitly.
  public var terminalHost: String
  /// Stable ECR identity: 1–40 letters, digits, underscores or hyphens.
  public var workstationId: String
  /// Terminal command TCP port. Default: 4100.
  public var payChannelPort: UInt16 = 4100
  /// Inbound terminal callback TCP port. Default: 4102.
  public var deviceChannelPort: UInt16 = 4102
  /// Terminal language: en, de, fr or it. Default: en. This does not localize application UI.
  public var language = "en"
  /// Merchant and customer receipt copies. Options default to Available for both; results may omit copies not supplied by the terminal.
  public var receipts = ReceiptHandling()
  /// Request Force Acceptance for payment when supported by the terminal. Default: false.
  public var forceAcceptance = false
  /// Optional protocol RequestFullPAN flag. Omitted by default. The structured card-number result remains masked.
  public var requestFullPan: Bool?
  /// Connection deadline in seconds. Default: 10.
  public var connectTimeout: TimeInterval = 10
  /// Exchange deadline in seconds. Default: 300.
  public var operationTimeout: TimeInterval = 300
  /// Abort acknowledgement deadline in seconds, capped by operationTimeout. Default: 10.
  public var abortTimeout: TimeInterval = 10
  /// Maximum abort attempts for one active transaction. Default: 3.
  public var maxAbortAttempts = 3
  /// Minimum delay between abort attempts in seconds. Default: 1.5.
  public var abortRetryDelay: TimeInterval = 1.5
  /// Enable bounded, sanitized SDK diagnostics. Default: false.
  public var loggingEnabled = false
  /// Diagnostic detail when logging is enabled. Default: normal.
  public var logLevel: OpiLogLevel = .normal
  /// Create a value using the supplied arguments.
  public init(terminalHost: String, workstationId: String) {
    self.terminalHost = terminalHost
    self.workstationId = workstationId
  }
  func validate() throws {
    guard !terminalHost.isEmpty,
      workstationId.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil,
      payChannelPort > 0, deviceChannelPort > 0, ["en", "de", "fr", "it"].contains(language),
      connectTimeout.isFinite, connectTimeout > 0, operationTimeout.isFinite, operationTimeout > 0,
      abortTimeout.isFinite, abortTimeout > 0, maxAbortAttempts > 0,
      abortRetryDelay.isFinite, abortRetryDelay >= 0
    else { throw OpiSdkError.invalidOptions }
  }
}
/// Thrown local validation, transport, lifecycle or persistence errors. A thrown error is not evidence that a financial transaction was declined.
public enum OpiSdkError: Error {
  case invalidOptions, invalidRequest, invalidXML, invalidFrame, terminalInUse, disposed,
    backgrounded, storageError
}
struct Pending: Codable, Sendable {
  var operation: OpiOperation
  var correlationId: String
  var requestId: String
  var amount: Int64?
  var currency: String?
  var reference: String?
}
