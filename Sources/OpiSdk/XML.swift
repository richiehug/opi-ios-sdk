import Foundation

final class XMLNode {
  let name: String
  let attrs: [String: String]
  var text = ""
  var children: [XMLNode] = []
  init(_ name: String, _ attrs: [String: String]) {
    self.name = name
    self.attrs = attrs
  }
  func all(_ name: String) -> [XMLNode] {
    (self.name == name ? [self] : []) + children.flatMap { $0.all(name) }
  }
  func first(_ name: String) -> XMLNode? { all(name).first }
  func value(_ name: String) -> String? {
    guard let s = first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
    else { return nil }
    return s
  }
}
private final class XMLReader: NSObject, XMLParserDelegate {
  var stack: [XMLNode] = []
  var root: XMLNode?
  var invalid = false
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if stack.count >= 64 {
      invalid = true
      parser.abortParsing()
      return
    }
    let n = XMLNode(elementName, attributes)
    if let p = stack.last { p.children.append(n) } else { root = n }
    stack.append(n)
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    stack.last?.text += String(data: data, encoding: .utf8) ?? ""
  }
  func parser(
    _ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?
  ) { _ = stack.popLast() }
}
func parseXML(_ xml: String) throws -> XMLNode {
  guard xml.utf8.count <= 4 * 1024 * 1024, !xml.uppercased().contains("<!DOCTYPE"),
    !xml.uppercased().contains("<!ENTITY")
  else { throw OpiSdkError.invalidXML }
  let reader = XMLReader()
  let p = XMLParser(data: Data(xml.utf8))
  p.shouldProcessNamespaces = true
  p.shouldResolveExternalEntities = false
  p.delegate = reader
  guard p.parse(), !reader.invalid, let root = reader.root else { throw OpiSdkError.invalidXML }
  return root
}
func escaped(_ s: String) -> String {
  s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&apos;")
}
func currencyDigits(_ c: String) throws -> Int {
  guard
    Locale.commonISOCurrencyCodes.contains(c) || ["CLF", "UYW", "UYI", "CHE", "CHW"].contains(c)
  else { throw OpiSdkError.invalidRequest }
  if ["CLF", "UYW"].contains(c) { return 4 }
  if ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"].contains(c) { return 3 }
  if [
    "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND",
    "VUV", "XAF", "XOF", "XPF",
  ].contains(c) {
    return 0
  }
  return 2
}
func major(_ n: Int64, _ c: String) throws -> String {
  let d = try currencyDigits(c)
  guard n >= 0 else { throw OpiSdkError.invalidRequest }
  var s = String(n)
  while s.count <= d { s = "0" + s }
  if d > 0 { s.insert(".", at: s.index(s.endIndex, offsetBy: -d)) }
  return s
}
func minor(_ s: String?, _ c: String?) -> Int64? {
  guard let s, let c, let d = try? currencyDigits(c),
    s.range(of: "^\\d+(\\.\\d+)?$", options: .regularExpression) != nil
  else { return nil }
  let a = s.split(separator: ".")
  let f = a.count > 1 ? String(a[1]) : ""
  if f.count > d && f.dropFirst(d).contains(where: { $0 != "0" }) { return nil }
  return Int64(
    String(a[0]) + String(f.prefix(d)) + String(repeating: "0", count: max(0, d - f.count)))
}
func buildRequest(_ o: OpiOptions, _ p: Pending, _ auth: String? = nil) throws -> String {
  let card = p.operation.financial || [.abort, .reprint, .repeatLastMessage].contains(p.operation)
  let root = card ? "CardServiceRequest" : "ServiceRequest"
  var xml =
    "<\(root) xmlns=\"http://www.nrf-arts.org/IXRetail/namespace\" WorkstationID=\"\(escaped(o.workstationId))\" RequestID=\"\(p.requestId)\" RequestType=\"\(p.operation.requestType)\""
  if let ref = p.reference { xml += " ReferenceNumber=\"\(escaped(ref))\"" }
  xml += "><POSdata LanguageCode=\"\(o.language)\""
  if card {
    xml += " RequestTransactionInformation=\"true\" RequestToken=\"true\""
    if let pan = o.requestFullPan { xml += " RequestFullPAN=\"\(pan)\"" }
    if ![.abort, .reprint, .repeatLastMessage].contains(p.operation) {
      xml += " RequestReceiptHeader=\"true\""
    }
    if let auth { xml += " TrxReferenceNumber=\"\(escaped(auth))\"" }
  }
  xml += "><POSTimeStamp>\(ISO8601DateFormatter().string(from:Date()))</POSTimeStamp>"
  if card {
    xml +=
      "<PrinterStatus>\(o.receipts.customerReceipt.rawValue)</PrinterStatus><E-JournalStatus>Available</E-JournalStatus><JournalPrinterStatus>\(o.receipts.merchantReceipt.rawValue)</JournalPrinterStatus>"
    if p.operation == .payment && o.forceAcceptance {
      xml += "<ForceAcceptance>true</ForceAcceptance>"
    }
  }
  xml += "</POSdata>"
  if let n = p.amount, let c = p.currency {
    xml += "<TotalAmount Currency=\"\(c)\">\(try major(n,c))</TotalAmount>"
  }
  return xml + "</\(root)>"
}
func deviceAck(_ n: XMLNode, _ op: OpiOperation) throws -> String {
  guard n.name == "DeviceRequest" else { throw OpiSdkError.invalidXML }
  let out = n.first("Output")?.attrs["OutDeviceTarget"]
  let input = n.first("Input")?.attrs["InDeviceTarget"]
  let confirm =
    input != nil && n.all("Command").contains(where: { $0.text == "GetConfirmation" })
    && (op == .reversal
      || n.all("TextLine").contains(where: {
        $0.text.range(
          of: "receipt|ticket|re[cç]u|quittance|beleg|bon",
          options: [.regularExpression, .caseInsensitive]) != nil
      }))
  var s =
    "<DeviceResponse xmlns=\"http://www.nrf-arts.org/IXRetail/namespace\" WorkstationID=\"\(escaped(n.attrs["WorkstationID"] ?? ""))\" RequestID=\"\(escaped(n.attrs["RequestID"] ?? ""))\" RequestType=\"\(escaped(n.attrs["RequestType"] ?? ""))\" OverallResult=\"Success\"><Output OutDeviceTarget=\"\(escaped(out ?? input ?? "CashierDisplay"))\" OutResult=\"Success\"/>"
  if let input {
    s +=
      "<Input InDeviceTarget=\"\(escaped(input))\" InResult=\"Success\"><InputValue>\(confirm ? "<InBoolean>true</InBoolean>":"")</InputValue></Input>"
  }
  return s + "</DeviceResponse>"
}
