import Foundation

// MARK: - AgentProtocol
//
// Wire-format for the iPhone → Mac tool-call channel. This file is the
// single source of truth on the iOS side and is duplicated verbatim on
// the LocalCoderBridge Mac side at:
//   LocalCoderBridge/LocalCoderBridge/Bridge/Agent/AgentProtocol.swift
// If you change one, change the other in the same commit.
//
// Why duplicate vs share a package:
//   The two apps live in separate projects with no SwiftPM linkage
//   today. Adding cross-project package wiring just for ~150 lines of
//   POD structs would balloon Phase 1 scope. Cost of drift is low —
//   schema is small, versioned, and only loaded via `AgentEnvelope`'s
//   own decoder, which catches mismatches at the boundary.
//
// Scope:
//   • Used ONLY by new tool-call messages (POST /v1/agent/*).
//   • The existing /v1/info and /v1/infer endpoints keep their bare
//     DTOs so older Mac builds keep working bit-for-bit.

// MARK: - Envelope

/// Generic envelope wrapping every agent message. `Payload` varies by
/// `type`; producers and consumers agree per-type which concrete type
/// to use. See `AgentMessageType` for the canonical pairings.
struct AgentEnvelope<Payload: Codable>: Codable {
    let version:   String     // "1.0" today; bump on breaking change
    let messageId: UUID
    let sessionId: UUID       // stable per connected pairing session
    let timestamp: Date       // wire-encoded ISO-8601 via Self.encoder
    let type:      AgentMessageType
    let sender:    AgentSender
    let payload:   Payload

    init(
        type: AgentMessageType,
        sender: AgentSender,
        sessionId: UUID,
        payload: Payload,
        messageId: UUID = UUID(),
        timestamp: Date = Date()
    ) {
        self.version   = AgentEnvelopeVersion.current
        self.messageId = messageId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.type      = type
        self.sender    = sender
        self.payload   = payload
    }
}

enum AgentEnvelopeVersion {
    static let current = "1.0"
}

enum AgentSender: String, Codable {
    case ios
    case mac
}

/// Message-type tag on every envelope. Stays a closed enum — unknown
/// values fail decode so we never silently accept unsupported messages.
enum AgentMessageType: String, Codable {
    case toolCall      = "tool_call"
    case toolResult    = "tool_result"
    case error         = "error"
    case toolsList     = "tools_list"
    case heartbeat     = "heartbeat"
}

// MARK: - Risk levels

/// Stays in lockstep with the Mac side. Phase 1 only routes SAFE_READ
/// through the wire — the other levels exist so we can grow into
/// approval-gated tools in Phase 3 without another schema bump.
enum RiskLevel: String, Codable {
    case safeRead     = "SAFE_READ"
    case lowRisk      = "LOW_RISK_ACTION"
    case mediumRisk   = "MEDIUM_RISK_ACTION"
    case highRisk     = "HIGH_RISK_ACTION"
}

// MARK: - Payloads

/// What the iPhone sends to invoke a single tool.
struct ToolCallPayload: Codable {
    let tool:              String        // dotted id, e.g. "mac.get_active_context"
    let risk:              RiskLevel
    let arguments:         JSONValue     // free-form per tool's input schema
    let requiresApproval:  Bool
    let userVisibleReason: String?       // shown in Mac audit log + approval UI
}

/// What the Mac returns after running a tool (or attempting to).
struct ToolResultPayload: Codable {
    let toolCallId: UUID                 // mirrors the inbound envelope.messageId
    let ok:         Bool
    let result:     JSONValue?           // populated when ok == true
    let error:      ToolErrorPayload?    // populated when ok == false
}

/// Standalone error envelope for protocol-level failures (e.g. unknown
/// tool, schema mismatch, auth rejected) — separate from a tool's own
/// failure which is reported via ToolResultPayload.error.
struct ToolErrorPayload: Codable {
    let code:        ToolErrorCode
    let message:     String              // human-readable, safe to display
    let recoverable: Bool
}

enum ToolErrorCode: String, Codable {
    case permissionDenied  = "PERMISSION_DENIED"
    case invalidSchema     = "INVALID_SCHEMA"
    case toolNotFound      = "TOOL_NOT_FOUND"
    case approvalRequired  = "APPROVAL_REQUIRED"
    case executionFailed   = "EXECUTION_FAILED"
    case timeout           = "TIMEOUT"
    case unauthorized      = "UNAUTHORIZED"
}

/// Returned by GET /v1/agent/tools/list — drives the iOS picker and
/// the prompt the local LLM gets ("you can call these tools").
struct ToolDescriptor: Codable {
    let tool:             String
    let description:      String
    let risk:             RiskLevel
    let requiresApproval: Bool
    let inputSchema:      JSONValue?     // simplified JSON-schema-ish dict
}

struct ToolsListPayload: Codable {
    let tools: [ToolDescriptor]
}

/// Liveness probe — the heartbeat path lets the iPhone confirm the
/// Mac side is reachable AND that the bearer + session are still good
/// before the LLM commits to a multi-step tool plan.
struct HeartbeatPayload: Codable {
    let nonce:      String                // echoed back
    let macName:    String?               // populated only on responses
    let pairedAt:   Date?
    let tools:      Int?                  // count of registered tools
}

// MARK: - JSON value

/// Codable JSON value tree. Used for tool arguments / results where
/// the shape is per-tool and not worth a generic erased container.
///
/// Why not `Any`: Codable doesn't natively support it. The other
/// common workaround is a per-tool typed payload, but that would
/// force ToolCallPayload itself to be generic — which then makes
/// AgentEnvelope doubly generic and harder to round-trip. Keeping
/// payload free-form here, typed at the tool handler, is the cheaper
/// trade for Phase 1.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)              { self = .bool(b); return }
        if let n = try? c.decode(Double.self)            { self = .number(n); return }
        if let s = try? c.decode(String.self)            { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)       { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .number(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }

    // MARK: - Convenience accessors

    /// Extract a string field from an `.object` — `nil` if the key is
    /// missing or the value isn't a string. Tool handlers use this to
    /// pull typed args without a full sub-decode step.
    func stringField(_ key: String) -> String? {
        guard case .object(let dict) = self,
              case .string(let s)? = dict[key] else { return nil }
        return s
    }

    func boolField(_ key: String) -> Bool? {
        guard case .object(let dict) = self,
              case .bool(let b)? = dict[key] else { return nil }
        return b
    }
}

// MARK: - Encoder / decoder

enum AgentCoding {
    /// Single shared encoder/decoder pair so both sides agree on
    /// date encoding (ISO-8601 with fractional seconds) and key
    /// ordering. Used by all `AgentEnvelope<…>` round-trips.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
