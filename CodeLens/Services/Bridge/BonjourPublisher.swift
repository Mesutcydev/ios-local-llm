import Foundation
import UIKit

// Advertises _localllm._tcp on the local network via mDNS so LocalCoderBridge
// on the Mac can discover this device without manual IP entry.
@MainActor
final class BonjourPublisher: NSObject {

    static let serviceType = "_localllm._tcp"

    private var service: NetService?

    func publish(port: UInt16, deviceId: String, certFingerprint: String, modelName: String) {
        stop()
        let txt = NetService.data(fromTXTRecord: [
            "id":    Data(deviceId.utf8),
            "cert":  Data(certFingerprint.utf8),
            "model": Data(modelName.utf8)
        ])
        // Advertise a NEUTRAL service name, not UIDevice.current.name — on
        // modern iOS that's often the user's real name ("Mesut's iPhone"),
        // which Bonjour would otherwise broadcast to every device on the LAN
        // the moment the Mac tab opens. A paired Mac still gets the friendly
        // name over the authenticated /v1/info channel.
        let neutralName = "CodeLens-" + String(deviceId.replacingOccurrences(of: "-", with: "").prefix(6))
        let svc = NetService(
            domain: "local.",
            type:   Self.serviceType,
            name:   neutralName,
            port:   Int32(port)
        )
        svc.delegate = self
        svc.setTXTRecord(txt)
        svc.publish()
        service = svc
    }

    func stop() {
        service?.stop()
        service = nil
    }
}

extension BonjourPublisher: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        print("[BonjourPublisher] Published: \(sender.name)")
    }
    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[BonjourPublisher] Failed: \(errorDict)")
    }
}
