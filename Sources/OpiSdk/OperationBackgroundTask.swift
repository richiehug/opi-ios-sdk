import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A finite operating-system grace period, never a guarantee of completion.
@MainActor
final class OperationBackgroundTask {
  private var expired = false
  private var ended = false
  private let expiration: @Sendable () -> Void
  #if canImport(UIKit)
  private var identifier: UIBackgroundTaskIdentifier = .invalid
  #endif

  init(expiration: @escaping @Sendable () -> Void) {
    self.expiration = expiration
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    // iPad apps running on a Mac do not use the iOS suspension lifecycle.
    guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
    identifier = UIApplication.shared.beginBackgroundTask(withName: "OPI financial operation") { [weak self] in
      self?.expire()
    }
    #endif
  }

  func expire() {
    guard !ended else { return }
    expired = true
    expiration()
    _ = finish()
  }

  @discardableResult
  func finish() -> Bool {
    guard !ended else { return expired }
    ended = true
    #if canImport(UIKit)
    if identifier != .invalid {
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
    #endif
    return expired
  }
}
