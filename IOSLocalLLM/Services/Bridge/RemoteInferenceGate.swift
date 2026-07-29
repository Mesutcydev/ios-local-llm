import Foundation

/// One admission point for inference initiated by any network server.
/// Local UI generation remains authoritative; remote requests fail fast while
/// the model is already generating instead of queueing surprising work.
actor RemoteInferenceGate {
    static let shared = RemoteInferenceGate()

    private var owner: UUID?

    func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID()
        owner = token
        return token
    }

    func release(_ token: UUID) {
        if owner == token { owner = nil }
    }
}
