import Foundation

// MARK: - BridgeAgentClient
//
// Outbound HTTP client the iPhone uses to talk to the paired Mac's
// /v1/agent/* endpoints. Wraps:
//   1. Picking the right target (Mac host + port + bearer) from
//      BridgePairingStore.
//   2. Building an AgentEnvelope around the tool call.
//   3. POSTing to the Mac with bearer auth.
//   4. Decoding the response envelope into a typed result.
//
// Phase 1 surfaces only the manual-test entry points the UI uses.
// Phase 3 will layer the agent loop on top of `callTool(_:arguments:)`.

@MainActor
final class BridgeAgentClient: ObservableObject {

    static let shared = BridgeAgentClient()

    private init() {}

    // MARK: - Errors

    enum AgentClientError: LocalizedError {
        case noPairedMac
        case malformedTarget
        case macUnreachable(String)
        case httpStatus(Int, String)
        case decodeFailed(String)
        case toolFailed(ToolErrorPayload)

        var errorDescription: String? {
            switch self {
            case .noPairedMac:
                return "No paired Mac with agent support. Pair (or re-pair) from the Mac tab first."
            case .malformedTarget:
                return "Paired Mac record is missing host/port info. Re-pair to fix."
            case .macUnreachable(let m):
                return "Could not reach Mac: \(m)"
            case .httpStatus(let code, let body):
                return "Mac returned HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
            case .decodeFailed(let m):
                return "Couldn't decode Mac response: \(m)"
            case .toolFailed(let err):
                return "Tool error (\(err.code.rawValue)): \(err.message)"
            }
        }
    }

    // MARK: - Public API

    /// Single ad-hoc invocation by tool name. The iPhone caller
    /// supplies the arguments + risk + reason; the client wraps the
    /// payload in an envelope and posts to /v1/agent/tools/call. On
    /// success returns the tool's `JSONValue` result; on tool-level
    /// failure throws `.toolFailed(payload)` so the UI can surface
    /// the structured error code.
    func callTool(
        _ tool: String,
        arguments: JSONValue = .object([:]),
        risk: RiskLevel = .safeRead,
        reason: String? = nil,
        sessionId: UUID = UUID()
    ) async throws -> JSONValue {
        let target = try resolveTarget()
        let payload = ToolCallPayload(
            tool:              tool,
            risk:              risk,
            arguments:         arguments,
            requiresApproval:  risk != .safeRead,
            userVisibleReason: reason
        )
        let envelope = AgentEnvelope(
            type:      .toolCall,
            sender:    .ios,
            sessionId: sessionId,
            payload:   payload
        )
        let resultEnvelope: AgentEnvelope<ToolResultPayload> = try await post(
            path:     "/v1/agent/tools/call",
            envelope: envelope,
            target:   target,
            timeout:  timeoutForRisk(risk)
        )
        if let value = resultEnvelope.payload.result, resultEnvelope.payload.ok {
            return value
        }
        if let err = resultEnvelope.payload.error {
            throw AgentClientError.toolFailed(err)
        }
        throw AgentClientError.decodeFailed("missing result and error in tool_result envelope")
    }

    /// Quick reachability + bearer check. Fires `bridge.heartbeat`
    /// against the Mac's /v1/agent/heartbeat shortcut endpoint with a
    /// fresh nonce, returns the parsed echo. The Mac UI test button
    /// uses this to confirm the wire end-to-end.
    func heartbeat() async throws -> HeartbeatResult {
        let target = try resolveTarget()
        let nonce = UUID().uuidString
        let payload = ToolCallPayload(
            tool:              HeartbeatToolName,
            risk:              .safeRead,
            arguments:         .object(["nonce": .string(nonce)]),
            requiresApproval:  false,
            userVisibleReason: "iPhone heartbeat probe"
        )
        let envelope = AgentEnvelope(
            type:      .toolCall,
            sender:    .ios,
            sessionId: UUID(),
            payload:   payload
        )
        let resp: AgentEnvelope<ToolResultPayload> = try await post(
            path:     "/v1/agent/heartbeat",
            envelope: envelope,
            target:   target,
            timeout:  timeoutForRisk(.safeRead)
        )
        guard resp.payload.ok, let result = resp.payload.result else {
            if let err = resp.payload.error { throw AgentClientError.toolFailed(err) }
            throw AgentClientError.decodeFailed("heartbeat returned no result")
        }
        guard let echoedNonce = result.stringField("nonce"), echoedNonce == nonce else {
            throw AgentClientError.decodeFailed("heartbeat nonce mismatch")
        }
        return HeartbeatResult(
            macName:    result.stringField("macName") ?? target.clientName,
            toolCount:  numberField(result, "toolCount").map(Int.init) ?? 0,
            macTime:    result.stringField("macTime") ?? "",
            roundTripMs: 0   // populated by caller via timing wrapper if needed
        )
    }

    /// Bundle of fields shown in the "Read active Mac context" card.
    /// Returned plain because the UI doesn't need the envelope.
    func activeContext(
        includeWindowTitle: Bool = true,
        includeSelectedText: Bool = true,
        includeClipboard: Bool = false
    ) async throws -> ActiveContextResult {
        let args: JSONValue = .object([
            "includeWindowTitle":  .bool(includeWindowTitle),
            "includeSelectedText": .bool(includeSelectedText),
            "includeClipboard":    .bool(includeClipboard)
        ])
        let result = try await callTool(
            "mac.get_active_context",
            arguments: args,
            reason:    "Read Mac context for the iPhone LLM"
        )
        return ActiveContextResult(
            frontmostApp:    result.stringField("frontmostApp"),
            bundleIdentifier: result.stringField("bundleIdentifier"),
            windowTitle:     result.stringField("windowTitle"),
            selectedText:    result.stringField("selectedText"),
            clipboardText:   result.stringField("clipboardText"),
            missingPermissions: missingPermissions(in: result)
        )
    }

    // MARK: - Target resolution

    private struct Target {
        let clientName: String
        let bearer:     String
        let host:       String
        let port:       UInt16
        /// Pinned Mac TLS leaf fingerprint; nil for legacy plaintext Macs.
        let pinnedFingerprint: String?
    }

    private func resolveTarget() throws -> Target {
        guard let client = BridgePairingStore.shared.firstAgentClient() else {
            throw AgentClientError.noPairedMac
        }
        guard let bearer = client.macBearerToken,
              let host = client.macHost,
              let port = client.macAgentPort else {
            throw AgentClientError.malformedTarget
        }
        return Target(clientName: client.clientName, bearer: bearer,
                      host: host, port: port,
                      pinnedFingerprint: client.macCertFingerprint)
    }

    // MARK: - HTTP plumbing

    /// SAFE_READ calls execute server-side immediately; anything
    /// risky parks in the Mac's approval queue while the user
    /// deliberates. Allow up to two minutes for the user to decide
    /// before the URLSession times out. Heartbeat + read tools keep
    /// the snappier 15-second budget.
    private func timeoutForRisk(_ risk: RiskLevel) -> TimeInterval {
        switch risk {
        case .safeRead:   return 15
        case .lowRisk, .mediumRisk, .highRisk: return 120
        }
    }

    /// Generic envelope POST. `Out` is whatever payload shape we
    /// expect inside the response envelope.
    private func post<In: Codable, Out: Codable>(
        path:     String,
        envelope: AgentEnvelope<In>,
        target:   Target,
        timeout:  TimeInterval = 15
    ) async throws -> AgentEnvelope<Out> {
        // HTTPS + cert-pinning when the Mac advertised a TLS fingerprint
        // at pairing; plaintext http only for legacy Macs that didn't.
        let scheme = target.pinnedFingerprint != nil ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(target.host):\(target.port)\(path)") else {
            throw AgentClientError.malformedTarget
        }
        let body: Data
        do { body = try AgentCoding.encoder.encode(envelope) }
        catch { throw AgentClientError.decodeFailed("encode failed: \(error.localizedDescription)") }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")

        let pinDelegate = target.pinnedFingerprint.map { BridgePinningDelegate(expectedFingerprint: $0) }
        let session: URLSession = pinDelegate.map {
            URLSession(configuration: .ephemeral, delegate: $0, delegateQueue: nil)
        } ?? .shared

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            if pinDelegate?.pinFailed == true {
                throw AgentClientError.macUnreachable("Mac TLS certificate changed since pairing — re-pair from the Mac tab.")
            }
            throw AgentClientError.macUnreachable(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw AgentClientError.decodeFailed("non-HTTP response")
        }
        // 4xx/5xx without an envelope go to .httpStatus so the UI
        // can show the server's plain-text body (e.g. "Unauthorized").
        if !(200...299).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw AgentClientError.httpStatus(http.statusCode, bodyStr)
        }
        do {
            return try AgentCoding.decoder.decode(AgentEnvelope<Out>.self, from: data)
        } catch {
            throw AgentClientError.decodeFailed(error.localizedDescription)
        }
    }

    // MARK: - JSONValue helpers

    private func numberField(_ value: JSONValue, _ key: String) -> Double? {
        guard case .object(let dict) = value,
              case .number(let n)? = dict[key] else { return nil }
        return n
    }

    private func missingPermissions(in value: JSONValue) -> [String] {
        guard case .object(let dict) = value,
              case .object(let perms)? = dict["permissions"],
              case .array(let missing)? = perms["missing"] else { return [] }
        return missing.compactMap {
            if case .string(let s) = $0 { return s } else { return nil }
        }
    }
}

// MARK: - Public result shapes

struct HeartbeatResult: Equatable {
    let macName:     String
    let toolCount:   Int
    let macTime:     String
    let roundTripMs: Int
}

struct ActiveContextResult: Equatable {
    let frontmostApp:       String?
    let bundleIdentifier:   String?
    let windowTitle:        String?
    let selectedText:       String?
    let clipboardText:      String?
    let missingPermissions: [String]

    var isEmpty: Bool {
        frontmostApp == nil && bundleIdentifier == nil && windowTitle == nil &&
            selectedText == nil && clipboardText == nil
    }
}

// MARK: - Tool name constants
//
// Kept in this file so iOS can reference the canonical names without
// importing the Mac's tool implementations. Stays in lockstep with
// the Mac side's `HeartbeatTool.name`, `GetActiveContextTool.name`.

private let HeartbeatToolName = "bridge.heartbeat"
