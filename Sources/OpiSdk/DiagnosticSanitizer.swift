import Foundation

/// Lexical edits preserve the original XML, including namespaces and mixed content.
/// This helper is used only on the copy passed to diagnostics.
enum DiagnosticSanitizer {
  static let panFields: Set<String> = ["pan", "cardpan", "cardnumber", "primaryaccountnumber", "applicationpan", "apppan", "maskedpan", "maskedcardnumber"]
  static let secretFields: Set<String> = ["track1", "track2", "track3", "trackdata", "track1data", "track2data", "expirydate", "expirationdate", "cardexpirydate", "pin", "pinblock", "cvv", "cvv2", "cvc", "cvc2", "cid", "securitycode", "token", "accesstoken", "authtoken", "password", "apppanenc", "encryptedpan"]
  static let textFields: Set<String> = ["text", "textline", "receipt", "receipttext", "display", "displaytext", "message", "merchantreceipt", "customerreceipt"]
  static func local(_ name: String) -> String {
    String(name.split(separator: ":").last ?? "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
  }
  static func replace(_ value: String, _ pattern: String, _ transform: (NSTextCheckingResult, String) -> String) -> String {
    let regex = try! NSRegularExpression(pattern: pattern)
    var result = value
    for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
      let range = Range(match.range, in: result)!
      result.replaceSubrange(range, with: transform(match, value))
    }
    return result
  }
  static func group(_ match: NSTextCheckingResult, _ index: Int, _ value: String) -> String {
    Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
  }
  static func decode(_ value: String) -> String {
    replace(value, #"(?i)&(?:#(x[0-9a-f]+|[0-9]+)|amp|lt|gt|quot|apos);"#) { match, source in
      let entity = group(match, 0, source), number = group(match, 1, source)
      if !number.isEmpty {
        let hex = number.lowercased().hasPrefix("x")
        if let code = UInt32(hex ? String(number.dropFirst()) : number, radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) { return String(scalar) }
      }
      return ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'"][entity] ?? entity
    }
  }
  static func maskPAN(_ value: String) -> String {
    let compact = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    if compact.isEmpty { return value }
    if compact.range(of: #"^[0-9Xx*•]{4,19}$"#, options: .regularExpression) != nil,
      compact.range(of: #"[Xx*•]"#, options: .regularExpression) != nil { return value }
    guard compact.range(of: #"^[0-9]{12,19}$"#, options: .regularExpression) != nil else { return "[REDACTED]" }
    var digit = 0
    return String(value.map { c in
      guard c >= "0", c <= "9" else { return c }
      let i = digit; digit += 1
      return i < 6 || i >= compact.count - 4 ? c : "X"
    })
  }
  static func luhn(_ value: String) -> Bool {
    var sum = 0, double = false
    for c in value.reversed() {
      var n = c.wholeNumberValue!
      if double { n *= 2; if n > 9 { n -= 9 } }
      sum += n; double.toggle()
    }
    return sum % 10 == 0
  }
  static func maskText(_ value: String) -> String {
    replace(value, #"(^|[^\w.*•-])([0-9Xx*•](?:[ -]?[0-9Xx*•]){11,})(?![\w.*•-])"#) { match, source in
      let whole = group(match, 0, source), prefix = group(match, 1, source), candidate = group(match, 2, source)
      if candidate.range(of: #"[Xx*•]"#, options: .regularExpression) != nil { return whole }
      let start = Range(match.range(at: 2), in: source)!.lowerBound
      let before = String(source[..<start].components(separatedBy: .newlines).last ?? "")
      let card = before.range(of: #"(?i)(?:\bPAN\b|\bcard(?:\s*(?:number|no\.?))?\b|\bKarte\b|\bcarte\b)\s*[:=#-]?\s*$"#, options: .regularExpression) != nil
      let reference = before.range(of: #"(?i)\b(?:ref(?:erence)?|transaction|trx|timestamp|date|time|amount|auth(?:orization)?|terminal|workstation|id)\b"#, options: .regularExpression) != nil
      let digits = candidate.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
      if !card && (reference || digits.count < 13 || digits.count > 19 || !luhn(digits)) { return whole }
      return prefix + maskPAN(candidate)
    }
  }
  static func field(_ name: String, _ raw: String, cdata: Bool = false) -> String {
    let value = cdata ? raw : decode(raw)
    var result: String
    if secretFields.contains(name) { result = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? value : "[REDACTED]" }
    else if panFields.contains(name) { result = maskPAN(value) }
    else if textFields.contains(name) { result = maskText(value) }
    else { result = value }
    result = result.replacingOccurrences(of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
    return result == value ? raw : cdata ? result : escaped(result)
  }
  static func xml(_ xml: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<\/?[\w:.-]+(?:"[^"]*"|'[^']*'|[^'">])*\/?>|[^<]+"#)
    var stack: [String] = [], result = ""
    for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
      let token = group(match, 0, xml)
      let context = stack.reversed().first { secretFields.contains($0) || panFields.contains($0) }
        ?? stack.reversed().first { textFields.contains($0) } ?? ""
      if token.hasPrefix("<![CDATA[") { result += "<![CDATA[" + field(context, String(token.dropFirst(9).dropLast(3)), cdata: true) + "]]>" }
      else if token.hasPrefix("<!--") { result += "<!--" + maskText(String(token.dropFirst(4).dropLast(3))) + "-->" }
      else if token.hasPrefix("<?") { result += token }
      else if token.hasPrefix("</") { _ = stack.popLast(); result += token }
      else if token.hasPrefix("<") {
        let name = local(String(token.dropFirst().prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }))
        result += replace(token, #"([\w:.-]+)(\s*=\s*)(["'])([\s\S]*?)\3"#) { m, s in
          let key = group(m, 1, s), equal = group(m, 2, s), quote = group(m, 3, s)
          let value = group(m, 4, s)
          return key + equal + quote + (key == "xmlns" || key.hasPrefix("xmlns:") ? value : field(local(key), value)) + quote
        }
        if !token.hasSuffix("/>") { stack.append(name) }
      } else { result += field(context, token) }
    }
    return result
  }
}
