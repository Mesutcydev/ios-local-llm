import Foundation
import UIKit

// MARK: - BridgeWakeup
// Lightweight wrapper around silent-push handling so a paired Mac can wake
// the iPhone bridge server when it's been backgrounded by iOS. The actual
// APNs send happens server-side (the Mac talks to Apple's push gateway with
// the device token registered via DeviceTokenStore below).
//
// Wiring (when push entitlement is enabled):
//   1. In AppDelegate / Scene didFinishLaunching, call:
//        UIApplication.shared.registerForRemoteNotifications()
//      and forward the result to `registerToken(...)`.
//   2. In application(_:didReceiveRemoteNotification:fetchCompletionHandler:),
//      call `BridgeWakeup.shared.handleSilentPush(...)`.
//
// Until APNs is configured this file is a no-op — the protocol stays compatible
// so the rest of the app can be built without push capability.

@MainActor
final class BridgeWakeup: ObservableObject {

    static let shared = BridgeWakeup()

    @Published private(set) var lastWokenAt: Date?
    @Published private(set) var deviceToken: String?

    private init() {}

    /// Called after registerForRemoteNotifications succeeds. The Mac uses this
    /// token to send the silent push (kind=bridge-wake) that wakes the iPhone.
    func registerToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        // Forward to paired Mac via existing pairing channel so the Mac knows
        // how to wake us. Best-effort — silently noop if no clients are paired.
        Task {
            // BridgeManager.shared.sendDeviceToken(hex)
            // ^ left as a future hook; depends on Mac protocol version.
        }
    }

    /// Invoked when a silent push arrives with payload {"kind":"bridge-wake"}.
    /// Starts (or re-starts) the bridge server so the next inference request
    /// from the Mac doesn't hang waiting for cold-launch.
    func handleSilentPush(payload: [AnyHashable: Any]) async {
        guard (payload["kind"] as? String) == "bridge-wake" else { return }
        lastWokenAt = Date()
        if BridgeManager.shared.serverState == .stopped {
            await BridgeManager.shared.start()
        }
    }
}
