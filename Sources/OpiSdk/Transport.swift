import Foundation
import Network

struct Exchange: Sendable {
  let xml: String
  let capture: Capture
}
struct TransportError: Error {
  let sent: Bool
  let reason: String
}
func frame(_ xml: String) throws -> Data {
  let payload = Data(xml.utf8)
  guard !payload.isEmpty, payload.count <= 4 * 1024 * 1024 else { throw OpiSdkError.invalidFrame }
  var n = UInt32(payload.count).bigEndian
  var out = withUnsafeBytes(of: &n) { Data($0) }
  out.append(payload)
  return out
}
struct Frames {
  var buffer = Data()
  mutating func push(_ data: Data) throws -> [String] {
    buffer.append(data)
    var items: [String] = []
    while buffer.count >= 4 {
      let n = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
      guard n > 0, n <= 4 * 1024 * 1024 else { throw OpiSdkError.invalidFrame }
      if buffer.count < n + 4 { break }
      guard let text = String(data: buffer.dropFirst(4).prefix(n), encoding: .utf8) else {
        throw OpiSdkError.invalidFrame
      }
      items.append(text)
      buffer = Data(buffer.dropFirst(n + 4))
    }
    return items
  }
}
// All mutable state is confined to queue. The continuation is completed exactly once.
final class TCPExchange: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.richiehug.opi.transport")
  private var connection: NWConnection?
  private var listener: NWListener?
  private var peers: [NWConnection] = []
  private var continuation: CheckedContinuation<Exchange, Error>?
  private var sent = false
  private var ready = false
  private var finished = false
  private var capture = Capture()
  private var finalFrames = Frames()
  private let options: OpiOptions
  private let pending: Pending
  private let xml: String
  private let control: Bool
  private let diagnostics: OpiDiagnostics
  private let emit: @Sendable (OperationEvent) -> Void
  init(
    _ options: OpiOptions, _ pending: Pending, _ xml: String, control: Bool = false,
    diagnostics: OpiDiagnostics,
    emit: @escaping @Sendable (OperationEvent) -> Void
  ) {
    self.options = options
    self.pending = pending
    self.xml = xml
    self.control = control
    self.diagnostics = diagnostics
    self.emit = emit
  }
  func run() async throws -> Exchange {
    try await withCheckedThrowingContinuation { c in
      queue.async {
        self.continuation = c
        if self.finished {
          c.resume(throwing: TransportError(sent: self.sent, reason: "CANCELLED"))
          self.continuation = nil
          return
        }
        let timeout = self.control
          ? min(self.options.abortTimeout, self.options.operationTimeout) : self.options.operationTimeout
        self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
          guard let self else { return }
          self.finish(.failure(TransportError(sent: self.sent,
            reason: self.control ? "ABORT_TIMEOUT" : "OPERATION_TIMEOUT")))
        }
        if self.control { self.connect() } else { self.listen() }
      }
    }
  }
  func hasSent() async -> Bool {
    await withCheckedContinuation { c in
      queue.async { c.resume(returning: self.sent && !self.finished) }
    }
  }
  func cancel() {
    queue.async {
      self.finish(.failure(TransportError(sent: self.sent, reason: "BACKGROUND_OR_CANCELLED")))
    }
  }
  private func finish(_ r: Result<Exchange, Error>) {
    guard !finished else { return }
    finished = true
    if case .failure(let error) = r {
      diagnostics.sdkError(code: (error as? TransportError)?.reason ?? "INVALID_FRAME")
    }
    connection?.stateUpdateHandler = nil
    connection?.viabilityUpdateHandler = nil
    connection?.pathUpdateHandler = nil
    connection?.cancel()
    peers.forEach { $0.cancel() }
    peers.removeAll()
    connection = nil
    let completion = continuation
    continuation = nil
    if let listener {
      listener.newConnectionHandler = nil
      // NWListener.cancel() is asynchronous. Rebinding before .cancelled races
      // the previous listener, especially during immediate recovery exchanges.
      listener.stateUpdateHandler = { [weak self] state in
        if case .cancelled = state {
          self?.listener = nil
          completion?.resume(with: r)
        }
      }
      listener.cancel()
    } else {
      completion?.resume(with: r)
    }
  }

  private func listen() {
    do {
      let tcp = NWProtocolTCP.Options()
      tcp.noDelay = true
      let parameters = NWParameters(tls: nil, tcp: tcp)
      parameters.allowLocalEndpointReuse = false
      let l = try NWListener(
        using: parameters, on: NWEndpoint.Port(rawValue: options.deviceChannelPort)!)
      listener = l
      l.stateUpdateHandler = { state in
        switch state {
        case .ready: self.connect()
        case .failed:
          self.finish(.failure(TransportError(sent: self.sent, reason: "CALLBACK_LISTENER_FAILED")))
        default: break
        }
      }
      l.newConnectionHandler = { peer in
        guard !self.finished else { peer.cancel(); return }
        // Numeric terminal addresses provide deterministic peer filtering on the callback channel.
        guard self.peers.count < 32, case .hostPort(let host, _) = peer.endpoint,
          host == NWEndpoint.Host(self.options.terminalHost)
        else {
          peer.cancel()
          return
        }
        self.peers.append(peer)
        peer.start(queue: self.queue)
        self.receiveDevice(peer, Frames())
      }
      l.start(queue: queue)
    } catch { finish(.failure(TransportError(sent: false, reason: "CALLBACK_LISTENER_FAILED"))) }
  }
  private func connect() {
    guard !finished else { return }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    // Probe TCP liveness without sending application messages or limiting terminal/cardholder activity.
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 5
    tcp.keepaliveInterval = 3
    tcp.keepaliveCount = 3
    let c = NWConnection(
      host: NWEndpoint.Host(options.terminalHost),
      port: NWEndpoint.Port(rawValue: options.payChannelPort)!,
      using: NWParameters(tls: nil, tcp: tcp))
    connection = c
    queue.asyncAfter(deadline: .now() + options.connectTimeout) { [weak self] in
      guard let self else { return }
      if !self.ready {
        self.finish(.failure(TransportError(sent: self.sent, reason: "CONNECT_TIMEOUT")))
      }
    }
    c.stateUpdateHandler = { state in
      switch state {
      case .ready:
        guard !self.ready, !self.finished else { return }
        self.ready = true
        do {
          let data = try frame(self.xml)
          self.sent = true
          c.send(
            content: data,
            completion: .contentProcessed { error in
              if error != nil {
                self.finish(
                  .failure(TransportError(sent: true, reason: "SEND_FAILED")))
              }
            })
          self.diagnostics.communication(direction: "sent", xml: self.xml)
          self.diagnostics.event(operation: self.pending.operation,
            correlationId: self.pending.correlationId, stage: "connected")
          self.emit(
            OperationEvent(
              operation: self.pending.operation, correlationId: self.pending.correlationId,
              kind: .connected))
          self.receiveFinal(c)
        } catch { self.finish(.failure(error)) }
      case .waiting where self.sent:
        self.finish(.failure(TransportError(sent: true, reason: "CONNECTION_LOST")))
      case .failed:
        self.finish(.failure(TransportError(sent: self.sent, reason: "CONNECTION_FAILED")))
      default: break
      }
    }
    c.viabilityUpdateHandler = { viable in
      if !viable && self.sent {
        self.finish(.failure(TransportError(sent: true, reason: "CONNECTION_LOST")))
      }
    }
    c.pathUpdateHandler = { path in
      if path.status == .unsatisfied && self.sent {
        self.finish(.failure(TransportError(sent: true, reason: "CONNECTION_LOST")))
      }
    }
    c.start(queue: queue)
  }
  private func receiveFinal(_ c: NWConnection) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
      guard !self.finished else { return }
      do {
        if let data, let xml = try self.finalFrames.push(data).first {
          self.diagnostics.communication(direction: "received", xml: xml)
          self.finish(.success(Exchange(xml: xml, capture: self.capture)))
          return
        }
        if done || error != nil {
          self.finish(.failure(TransportError(sent: self.sent, reason: "CONNECTION_CLOSED")))
          return
        }
        self.receiveFinal(c)
      } catch { self.finish(.failure(TransportError(sent: self.sent, reason: "INVALID_FRAME"))) }
    }
  }
  private func receiveDevice(_ peer: NWConnection, _ input: Frames) {
    peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
      guard !self.finished else { return }
      var decoder = input
      do {
        if let data {
          for xml in try decoder.push(data) {
            let root = try parseXML(xml)
            let ackXML = try deviceAck(root, self.pending.operation)
            let ack = try frame(ackXML)
            peer.send(content: ack, completion: .contentProcessed { _ in })
            // Queue diagnostic work only after submitting the callback ACK.
            self.diagnostics.communication(direction: "callback", xml: xml)
            self.diagnostics.communication(direction: "ack", xml: ackXML)
            let count = self.capture.messages.count
            let previousReceipts = self.capture.receipts
            let previousDcc = self.capture.dcc?.amount
            captureDevice(root, &self.capture)
            for text in self.capture.messages.dropFirst(count) {
              self.emit(
                OperationEvent(
                  operation: self.pending.operation, correlationId: self.pending.correlationId,
                  kind: .terminalMessage, message: text))
            }
            if let receipt = self.capture.receipts.merchantReceipt,
              receipt.content != previousReceipts.merchantReceipt?.content
            {
              self.emit(
                OperationEvent(
                  operation: self.pending.operation, correlationId: self.pending.correlationId,
                  kind: .receiptCaptured, receipt: receipt, receiptType: "merchant"))
            }
            if let receipt = self.capture.receipts.customerReceipt,
              receipt.content != previousReceipts.customerReceipt?.content
            {
              self.emit(
                OperationEvent(
                  operation: self.pending.operation, correlationId: self.pending.correlationId,
                  kind: .receiptCaptured, receipt: receipt, receiptType: "customer"))
            }
            if self.capture.dcc != nil, self.capture.dcc?.amount != previousDcc {
              self.emit(
                OperationEvent(
                  operation: self.pending.operation, correlationId: self.pending.correlationId,
                  kind: .dccCaptured))
            }
          }
        }
        if done || error != nil { self.closePeer(peer) } else { self.receiveDevice(peer, decoder) }
      } catch { self.closePeer(peer) }
    }
  }

  private func closePeer(_ peer: NWConnection) {
    peers.removeAll { $0 === peer }
    peer.cancel()
  }
}
