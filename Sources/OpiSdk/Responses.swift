import Foundation

struct Capture: Sendable {
  var messages: [String] = []
  var receipts = ReceiptDetails()
  var journal: TransactionResult?
  var dcc: DccDetails?
}
func maskPAN(_ s: String?) -> String? {
  guard let s, !s.isEmpty else { return nil }
  if s.contains(where: { "*xX•".contains($0) }) { return s }
  guard s.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return nil }
  let d = s.filter(\.isNumber)
  return String(repeating: "*", count: max(0, d.count - 4)) + d.suffix(4)
}
func captureDevice(_ n: XMLNode, _ c: inout Capture) {
  let out = n.first("Output")
  let target = out?.attrs["OutDeviceTarget"]
  let ticket = out?.attrs["TicketType"]
  let lines = n.all("TextLine").map { $0.text.replacingOccurrences(of: "\r", with: "") }
  if ["CashierDisplay", "Display"].contains(target ?? "") {
    c.messages += lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
  }
  if ["Printer", "JournalPrinter"].contains(target ?? ""), ticket != "DccOffer",
    !lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  {
    let r = Receipt(lines.joined(separator: "\n"))
    if ticket == "CustomerReceipt" {
      c.receipts.customerReceipt = r
    } else if ticket == "MerchantReceipt" || target == "JournalPrinter" {
      c.receipts.merchantReceipt = r
    } else if ticket == nil {
      c.receipts.customerReceipt = r
    }
  }
  if n.first("TransactionInfo") != nil {
    let currency = n.first("TotalAmount")?.attrs["Currency"]
    c.journal = TransactionResult(
      amount: minor(n.value("TotalAmount") ?? n.value("DetailedAmount"), currency),
      currency: currency, paymentMethod: n.value("CardLabelName"),
      maskedCardNumber: maskPAN(n.value("CardNumber")),
      authReference: n.value("TransactionRefNumber") ?? n.value("TrxReferenceNumber"),
      approvalCode: n.value("AuthorisationCode") ?? n.value("AuthorizationCode"),
      transactionDate: n.value("DateAndTime"), acquirerId: n.value("AcquirerIdentifier"))
  }
  if n.first("DccInfo") != nil || n.first("DCCInfo") != nil {
    c.dcc = DccDetails(
      amount: n.value("CardHolderBillingAmount"),
      currency: n.value("CardHolderBillingCurrencyName")?.uppercased(),
      currencyCode: n.value("CardHolderBillingCurrencyCode"),
      exchangeRate: n.value("Exchangerate") ?? n.value("ExchangeRate"),
      markupPercentage: n.value("CommissionPercentage") ?? n.value("MarkupPercentage"))
  }
}
func parseResult(_ xml: String, _ p: Pending, _ c: Capture, _ override: String? = nil) throws
  -> OpiResult
{
  let n = try parseXML(xml)
  guard ["CardServiceResponse", "ServiceResponse"].contains(n.name) else {
    throw OpiSdkError.invalidXML
  }
  let code = (override ?? n.attrs["OverallResult"] ?? n.value("OverallResult") ?? "Unknown")
    .uppercased()
  let diag = n.first("Diagnosis")
  let host = n.value("HostDeclineReason") ?? diag?.attrs["HostDeclineReason"]
  let reason = n.value("TerminalDeclineReason") ?? diag?.attrs["TerminalDeclineReason"]
  var state: ResultState = .terminalError
  switch code {
  case "SUCCESS", "ACTIVATED", "ALREADYACTIVATED", "DEACTIVATED", "ALREADYDEACTIVATED", "DAYCLOSED":
    state = .success
  case "ABORTED": state = .aborted
  case "BUSY": state = .inProgress
  case "UNKNOWN": state = .unknown
  case "CONNECTIONERROR", "FLOWTIMEDOUT": state = .communicationError
  case "FORMATERROR", "MISSINGMANDATORYDATA", "PARSINGERROR", "VALIDATIONERROR":
    state = .invalidRequest
  case "FAILURE":
    if reason == "107" { state = .aborted } else if let host, host != "0" { state = .declined }
  default: break
  }
  let hints = c.messages.joined().folding(
    options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")
  ).filter(\.isLetter)
  if code == "FAILURE" {
    if [.activate, .login].contains(p.operation),
      [
        "activationfinished", "activationcompleted", "alreadyactivated", "alreadyactive",
        "aktivierungabgeschlossen", "bereitsaktiviert", "activationterminee", "dejaactive",
        "attivazionecompletata", "giaattivo",
      ].contains(where: hints.contains)
    {
      state = .success
    }
    if [.deactivate, .logoff].contains(p.operation),
      [
        "deactivationfinished", "deactivationcompleted", "alreadydeactivated", "alreadyinactive",
        "deaktivierungabgeschlossen", "bereitsdeaktiviert", "desactivationterminee",
        "disattivazionecompletata",
      ].contains(where: hints.contains)
    {
      state = .success
    }
    if p.operation.financial,
      [
        "paymentaborted", "transactionaborted", "paymentcancelled", "transactioncancelled",
        "zahlungabgebrochen", "transaktionabgebrochen", "paiementannule", "pagamentoannullato",
      ].contains(where: hints.contains)
    {
      state = .aborted
    }
  }
  var r = OpiResult(
    status: state, correlationId: p.correlationId,
    errorCode: state == .success
      ? nil
      : host.flatMap { $0 != "0" ? $0 : nil } ?? reason.flatMap { $0 != "0" ? $0 : nil } ?? code)
  let total = n.first("TotalAmount")
  let currency = total?.attrs["Currency"] ?? c.journal?.currency ?? p.currency
  var amount = minor(total?.text, currency) ?? c.journal?.amount ?? p.amount
  if p.operation == .reversal, state == .success, amount == 0, c.journal?.currency == currency,
    let a = c.journal?.amount, a > 0
  {
    amount = a
  }
  if p.operation.financial || p.operation == .reprint {
    var t = c.journal ?? TransactionResult()
    t.reference = p.reference ?? n.attrs["ReferenceNumber"] ?? n.value("ReferenceNumber")
    t.amount = amount
    t.currency = currency
    let auth = n.first("Authorisation")
    t.paymentMethod = normalizePaymentMethod(n.value("CardCircuit") ?? auth?.attrs["CardCircuit"] ?? t.paymentMethod)
    t.maskedCardNumber =
      maskPAN(n.value("MaskedCardNumber") ?? auth?.attrs["MaskedCardNumber"]) ?? t.maskedCardNumber
    t.authReference =
      n.value("TrxReferenceNumber") ?? auth?.attrs["TrxReferenceNumber"] ?? n.value(
        "TransactionRefNumber") ?? t.authReference
    t.approvalCode = n.value("ApprovalCode") ?? auth?.attrs["ApprovalCode"] ?? t.approvalCode
    t.transactionDate = n.value("TimeStamp") ?? auth?.attrs["TimeStamp"] ?? t.transactionDate
    t.receipts = c.receipts
    let messages = c.messages.joined(separator: " ")
    let currencyPattern = try! NSRegularExpression(
      pattern: "\\b([A-Z]{3})\\s+[0-9]+(?:[.,][0-9]+)?\\b")
    let offeredCurrencies = Set(
      currencyPattern.matches(in: messages, range: NSRange(messages.startIndex..., in: messages))
        .compactMap { match in Range(match.range(at: 1), in: messages).map { String(messages[$0]) }
        })
    let offered =
      messages.range(
        of: "choose currency|exchange rate|ex\\.?\\s*rate|wechselkurs|mark-?up",
        options: [.regularExpression, .caseInsensitive]) != nil || offeredCurrencies.count >= 2
    if offered, c.dcc?.amount != nil, c.dcc?.currency != nil || c.dcc?.currencyCode != nil {
      t.dcc = c.dcc
    }
    if p.operation == .payment, state == .success, currency == p.currency, let amount,
      let requested = p.amount, amount > requested
    {
      t.tip = amount - requested
    }
    r.transaction = t
  }
  var terminal: [String: String] = [:]
  for (k, v) in [
    "terminalId": "TerminalID", "terminalIp": "TerminalIP", "appVersion": "AppVersion",
    "merchantId": "Ep2MID", "status": "TerminalStatus", "subStatus": "TerminalSubStatus",
    "hardware": "Hardware", "serialNumber": "SerialNumber",
    "configurationName": "ConfigurationName", "configurationVersion": "ConfigurationVersion",
  ] { terminal[k] = n.value(v) ?? n.first("Identification")?.attrs[v] }
  r.terminal = terminal
  return r
}

private func normalizePaymentMethod(_ value: String?) -> String? {
  guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
  let code = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
  switch code {
  case "VISA": return "visa"
  case "MASTERCARD": return "mastercard"
  case "ECMC": return "mastercard"
  case "MAESTRO": return "maestro"
  case "MAES": return "maestro"
  case "VPAY": return "vpay"
  case "AMEX": return "amex"
  case "JCB": return "jcb"
  case "DINERS": return "diners"
  case "DINC": return "diners"
  case "DISCOVER": return "discover"
  case "DISC": return "discover"
  case "UNIONPAY": return "unionpay"
  case "UNUP": return "unionpay"
  case "GIROCARD": return "girocard"
  case "TWINT": return "twint"
  case "TWNT": return "twint"
  default: return raw.lowercased()
  }
}
