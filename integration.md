# Integrating the OPI iOS SDK

## Installation and network permission

In Xcode, add `https://github.com/richiehug/opi-ios-sdk.git` with an exact version requirement of **1.0.0**, then link the **OpiSdk** product to your application.

For an application managed with `Package.swift`:

```swift
.package(url: "https://github.com/richiehug/opi-ios-sdk.git", exact: "1.0.0")
```

Add `.product(name: "OpiSdk", package: "opi-ios-sdk")` to the consuming target's dependencies. Use one client per terminal. `terminalHost` currently accepts a numeric IPv4 or IPv6 address so the callback channel can verify its peer. The terminal uses port 4100 for commands and must connect back to this device's IP on port 4102. These ports are configurable on `OpiOptions`.

Add this key to the **application's** Info.plist:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connect to your payment terminal and receive transaction messages and receipts.</string>
```

Allow Local Network access when iOS asks. If denied, enable it under iOS Settings for your app. Direct TCP connections do not need Bonjour declarations or multicast entitlements. Provision the terminal with the phone/iPad's current Wi-Fi address and callback port. Network.framework failures or permission denial cannot be treated as a declined payment.

## Configure the client

```swift
var options = OpiOptions(terminalHost: "192.168.0.69", workstationId: "ECR-01")
options.payChannelPort = 4100
options.deviceChannelPort = 4102
options.language = "en"
options.receipts = ReceiptHandling(merchantReceipt: .available, customerReceipt: .available)
options.forceAcceptance = false
options.connectTimeout = 10
options.operationTimeout = 300
options.abortTimeout = 10
options.loggingEnabled = false
options.logLevel = .normal
let terminal = try OpiClient(options: options)
```

Timeouts use seconds. The language setting controls terminal requests, not your application's labels. The ECR owns transaction storage.

The SDK ends an exchange as soon as Network.framework reports that its established connection is no longer viable, is waiting for a network, or has lost its path. It does not wait for reconnection and silently resume that exchange. TCP keepalive probes also help detect a silent broken connection (5 seconds idle, 3 probes spaced 3 seconds apart); operating-system detection time is not an exact deadline. `operationTimeout` remains the overall limit for an otherwise connected terminal that stops responding. A quiet terminal during PIN entry is not itself a network failure.

## Lifecycle

Retain the client outside transient views and observe its events in a long-lived task. The SDK uses `UIApplication.beginBackgroundTask` for each active financial exchange so an iOS/iPadOS app can finish its OPI communication during the finite background grace period. It ends the task when the exchange finishes.

If iOS expires the task first, the SDK safely closes the exchange and returns `RESULT_UNKNOWN`. It never sends `AbortRequest` automatically. Background execution time is limited by iOS; process termination cannot deliver a result to a dead application, so the ECR must persist its own transaction intent.

No Background Modes capability or additional `Info.plist` entry is needed for this handling. The existing local-network permission is still required. Normal iOS/iPadOS applications are supported; app extensions are out of scope. Call `dispose()` after operations finish. `close()` is the terminal close-day command.

## Commands and outcomes

Use `try await` with `payment(PaymentRequest)`, `refund(PaymentRequest, authReference:)`, `reversal()`, `abort()`, `reprint()`, `repeatLastMessage()`.

Terminal operations are `login()`, `logoff()`, `activate()`, `deactivate()`, `info()`, `status()`, `initialize()`, `config()`, `submit()`, `close()` and `reset()`. `perform(OpiOperation)` is available for service operations. `close()` means close-day; `dispose()` releases the client.

Amounts use integer minor units: CHF 10.00 is `1000`. Overlapping commands return `PENDING_TRANSACTION`; abort uses a separate connection. Invalid input/options throw; terminal outcomes are returned through `OpiResult.status` and `errorCode`. Handle both. Unknown is not failure/decline, and a previous recovered payment is not approval of a newly requested sale.

## Events, receipts and DCC

```swift
for await event in terminal.events {
    switch event.kind {
    case .terminalMessage: await MainActor.run { /* display event.message */ }
    case .receiptCaptured: /* store event.receipt and event.receiptType */ break
    default: break
    }
}
```

Both receipt copies default to `.available`, returning text to your app. Choose `.printLocal` explicitly only for a terminal with a working printer. E-journal remains Available. Preserve receipt spacing in a monospace view. Missing copies do not invalidate a confirmed financial approval, but require separate receipt recovery when your checkout needs them.

`result.transaction` provides terminal-supplied amount/currency, tip, method, masked PAN, authorization references, receipts and DCC. Successful reversal summaries reporting zero use a positive same-currency journal amount from the same exchange when available. Existing nonzero terminal amounts remain authoritative.

Receipt confirmations and confirmations for an explicitly requested reversal are acknowledged automatically. The SDK does not automatically consent to unrelated payment prompts.

## Transaction state and reconciliation

**SDK owns OPI communication; ECR owns transaction state and reconciliation.**

The SDK keeps no persistent transaction ledger or cross-restart transaction lock. An overlapping operation is rejected with `PENDING_TRANSACTION` while an exchange is active. Save the sale intent, terminal identity, result and receipts in your ECR.

`payment()` → `PRINTLASTTICKET` → ECR decides → `reprint()` if required → ECR explicitly starts a new payment.

`PRINTLASTTICKET` is returned unchanged. The SDK does not reprint, reconcile an older sale, check readiness, or retry the new payment automatically. A successful reprint does not start another payment.

If a financial request may have been sent but its final response is lost or unusable, the SDK returns `UNKNOWN` / `RESULT_UNKNOWN`. This is neither approval nor proof of failure. Keep the sale unresolved and **do not blindly retry**: reconcile using the terminal/acquirer records and any explicitly requested evidence. `transportErrorCode` distinguishes observed connection loss/closure, operation timeout and background expiration when available. A connection failure before transmission returns a communication/connection error. A definitive terminal response preserves its outcome and error code, including an approval that arrives before the operating system detects a brief network interruption.

`repeatLastMessage()` explicitly requests the terminal's last registered message. `reprint()` explicitly requests its last receipt and available transaction details using the configured receipt handling. These are distinct commands; neither calls the other. The ECR must correlate their evidence with its own sale, especially if another ECR has used the terminal. Neither command updates an SDK ledger.

An `AbortRequest` acknowledgement does not prove that a financial transaction was cancelled. Keep awaiting the original financial result. If that response is lost, its outcome remains unknown; do not infer cancellation from an abort acknowledgement or closed socket.

Abort acknowledgement has its own `abortTimeout` (10 seconds by default, capped by `operationTimeout`). Its timeout returns `ABORT_UNAVAILABLE` with `transportErrorCode == "ABORT_TIMEOUT"`; the original financial request continues. When that original request finishes, an outstanding abort connection is closed so a missing abort acknowledgement cannot keep the payment result waiting. Enable Abort only after `.connected`, disable it when the original operation completes, and dismiss the working overlay for every final outcome including unknown. Do not send Abort as a way to repair a disconnected terminal or cancel a payment whose outcome is already unknown.

For a cashier network-disconnect incident, retain the original intent and correlation ID, final outcome, transport diagnostic, terminal transaction reference, and both receipt copies as separate evidence. On reconnection, use explicit RepeatLastMessage to investigate the outcome and TicketReprint to retrieve receipts. Match the evidence to the original sale before updating it. A new payment is an explicit cashier decision after reconciliation, never an automatic retry following an empty reprint.

## Diagnostics

SDK logging defaults to off. Enable `loggingEnabled` for support; `.normal` records operation lifecycle, while `.extended` adds sanitized protocol structure and SDK error codes. Read the bounded diagnostic log with `await OpiDiagnostics.read()` and clear it with `try await OpiDiagnostics.clear()`. File handling runs off the transport queue, and callback acknowledgements are submitted before protocol logging. Receipt text, card data and tokens are redacted. These logs are diagnostic evidence, not a transaction ledger or application crash logger.

## Interpreting results

| Outcome | Application action |
| --- | --- |
| Success | Complete the sale and retain its transaction details. |
| Declined | Show the decline and preserve the error code. |
| Aborted | Show cancellation after the original financial operation completes. |
| Unknown / InProgress | Keep an uncertain record and reconcile; do not blindly retry payment. |
| CommunicationError / TerminalError | Preserve the result and error code; inspect transaction/recovery context. |
| InvalidRequest or thrown validation/storage error | Correct the local setup or request. Do not infer a terminal decline from an exception. |

Optional card, receipt and DCC fields are absent when the terminal does not provide them. Do not fill missing data from another transaction. An abort acknowledgement or receipt alone does not override the original financial result.

### Payment method normalization

`transaction.paymentMethod` uses the same lowercase brand identifiers as the Android and .NET SDKs: `visa`, `mastercard`, `maestro`, `vpay`, `amex`, `jcb`, `diners`, `discover`, `unionpay`, `girocard`, and `twint`. Terminal aliases such as `ECMC`, `MAES`, `DINC`, `DISC`, `UNUP`, and `TWNT` map to these identifiers. Case, punctuation and surrounding whitespace are ignored when recognizing known brands. Blank values are absent; unknown brands retain their trimmed text in lowercase. This applies to the final response and callback-derived transaction information. Display names and logos remain application-owned.
