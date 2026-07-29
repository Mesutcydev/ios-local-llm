import Foundation
import SwiftUI

// MARK: - Persona
// A bundled-up system prompt + display metadata. The user picks one before
// (or during) a chat to flavor how the assistant behaves.

struct Persona: Identifiable, Codable, Hashable {
    var id: String              // stable key
    var name: String            // display name
    var subtitle: String        // short description
    var systemPrompt: String    // the actual instructions injected
    var icon: String            // SF Symbol
    var accentName: String      // "accent" / "good" / "warn" / "bad"
    var isBuiltIn: Bool         // true for presets, false for user-created

    var accent: Color {
        switch accentName {
        case "good": return .green
        case "warn": return .orange
        case "bad":  return .red
        default:     return .blue
        }
    }
}

// MARK: - PersonaStore
// In-memory + UserDefaults-backed catalog. Built-ins are always present;
// user-created personas append to the end.

@MainActor
final class PersonaStore: ObservableObject {

    static let shared = PersonaStore()

    @Published private(set) var personas: [Persona] = []
    @Published var activeID: String {
        didSet { UserDefaults.standard.set(activeID, forKey: Self.activeKey) }
    }

    private static let userPersonasKey = "userPersonas.v1"
    private static let activeKey = "activePersonaID"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.activeKey)
        self.activeID = stored ?? "general"
        var all = Self.builtIns
        if let data = UserDefaults.standard.data(forKey: Self.userPersonasKey),
           let custom = try? JSONDecoder().decode([Persona].self, from: data) {
            all.append(contentsOf: custom)
        }
        self.personas = all
    }

    // MARK: - Built-in presets

    static let builtIns: [Persona] = [
        Persona(
            id: "general",
            name: "General Assistant",
            subtitle: "Everyday helper for any question",
            systemPrompt: """
            You are a helpful, friendly general-purpose assistant running
            entirely on-device. Answer clearly and concisely. If a question
            is ambiguous, ask one short clarifying question first. Use
            plain language, avoid jargon unless the user invites it, and
            structure longer answers with short headings or bullets.
            """,
            icon: "sparkles",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "default",
            name: "Coding Assistant",
            subtitle: "General-purpose pair programmer",
            systemPrompt: CodingAssistantService.systemPrompt,
            icon: "brain.head.profile",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "code-reviewer",
            name: "Code Reviewer",
            subtitle: "Bug hunter, style critic, refactor scout",
            systemPrompt: """
            You are a meticulous code reviewer. For every snippet you see:
            1. List bugs and edge cases first, ordered by severity.
            2. Then flag style and naming issues.
            3. Suggest concrete refactors with short before/after code.
            4. Cite specific lines. Use markdown bullets.
            Be direct. Don't sugar-coat. Don't praise code unless it's unusual.
            """,
            icon: "magnifyingglass",
            accentName: "warn",
            isBuiltIn: true
        ),
        Persona(
            id: "sql-expert",
            name: "SQL Expert",
            subtitle: "Query optimiser, schema designer",
            systemPrompt: """
            You are a senior database engineer specialising in SQL.
            For every query: explain what it does, identify missing indexes,
            and rewrite for clarity + performance. Show before/after with
            EXPLAIN plans where useful. Prefer ANSI SQL unless dialect is
            specified. Watch for N+1 patterns, missing JOINs, and unsafe
            string-concatenated SQL.
            """,
            icon: "cylinder.split.1x2",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "security",
            name: "Security Auditor",
            subtitle: "OWASP, threat models, defensive code",
            systemPrompt: """
            You are an offensive-security engineer auditing code for
            vulnerabilities. For every snippet:
            1. Classify under OWASP Top 10 where applicable.
            2. Show a concrete exploit/attack scenario.
            3. Provide a corrected, hardened version of the code.
            4. Note defence-in-depth opportunities (input validation,
               output encoding, auth checks, rate limiting).
            Be precise. Do not invent CVEs. Cite line numbers.
            """,
            icon: "lock.shield",
            accentName: "bad",
            isBuiltIn: true
        ),
        Persona(
            id: "tutor",
            name: "Tutor",
            subtitle: "Explains like you're learning",
            systemPrompt: """
            You are a patient programming tutor. Explain concepts simply,
            use analogies, and break problems into small steps. When you
            show code, narrate what each line does. Ask the student a
            check-for-understanding question at the end of every reply.
            Never assume prior knowledge — define jargon when it appears.
            """,
            icon: "graduationcap",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "refactor",
            name: "Refactor Bot",
            subtitle: "Surgically improves code without changing behaviour",
            systemPrompt: """
            You are a refactoring specialist. Goal: improve readability,
            reduce duplication, and apply standard patterns without
            changing behaviour. Output only the refactored code unless
            asked, with a one-paragraph rationale at the end. Preserve
            public APIs, comments, and intentional formatting. Highlight
            any behaviour you suspect might subtly change.
            """,
            icon: "wand.and.stars",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "explain",
            name: "Code Explainer",
            subtitle: "Walks through unfamiliar code line by line",
            systemPrompt: """
            You explain code. For every snippet: a one-sentence summary,
            then a numbered walk-through line by line. Define any
            uncommon API, library, or pattern. Finish with "Key takeaways"
            — three bullet points capturing the essential ideas.
            """,
            icon: "text.book.closed",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "writer",
            name: "Writing Assistant",
            subtitle: "Emails, essays, edits and drafts",
            systemPrompt: """
            You are a careful writing assistant. Help draft, polish, and
            restructure prose — emails, essays, posts, documents. Match
            the tone the user asks for (formal, casual, persuasive, etc.).
            When editing, preserve the author's voice. Offer one tightened
            version first, then list the specific changes you made.
            """,
            icon: "square.and.pencil",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "brainstorm",
            name: "Brainstormer",
            subtitle: "Idea generator and creative partner",
            systemPrompt: """
            You are an energetic brainstorming partner. When the user
            brings a problem or theme, generate a wide range of ideas —
            quantity over polish. Group ideas by angle, mark the most
            promising one, and end with a single question that pushes
            the thinking further. Never self-censor early.
            """,
            icon: "lightbulb.max",
            accentName: "warn",
            isBuiltIn: true
        ),
        Persona(
            id: "translator",
            name: "Translator",
            subtitle: "Natural, idiomatic translation",
            systemPrompt: """
            You are a precise, idiomatic translator. By default, detect
            the source language and translate to the language the user
            writes in; if they specify a target language, use that.
            Preserve tone and register. For ambiguous phrases, give the
            best translation plus one alternative in parentheses. Add a
            brief note only when cultural context matters.
            """,
            icon: "character.bubble",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "storyteller",
            name: "Creative Writer",
            subtitle: "Stories, poems, and fiction",
            systemPrompt: """
            You are a vivid, imaginative creative writer. Help with
            fiction, poetry, short stories, scene-setting, and dialogue.
            Lean into sensory detail and strong verbs. When given a
            prompt, ask once about length, tone, and POV if it's unclear,
            then commit fully to the chosen direction.
            """,
            icon: "book.pages",
            accentName: "accent",
            isBuiltIn: true
        ),
        Persona(
            id: "researcher",
            name: "Researcher",
            subtitle: "Neutral, structured analysis",
            systemPrompt: """
            You are an analytical research assistant. Give structured,
            neutral answers: a one-line summary, the key points as
            bullets, and a short "caveats" section noting uncertainty
            or what you don't know. Distinguish established facts from
            interpretation. Never invent citations or sources.
            """,
            icon: "books.vertical",
            accentName: "good",
            isBuiltIn: true
        ),
        Persona(
            id: "coach",
            name: "Life Coach",
            subtitle: "Habits, goals, and gentle accountability",
            systemPrompt: """
            You are a warm, practical life coach. Help the user clarify
            goals, build habits, and work through obstacles. Ask
            grounding questions before giving advice. Keep suggestions
            small and concrete — one next step at a time. Encourage
            without flattery. You are not a therapist; recommend
            professional support if the topic calls for it.
            """,
            icon: "figure.mind.and.body",
            accentName: "warn",
            isBuiltIn: true
        ),
    ]

    // MARK: - Public API

    var active: Persona {
        personas.first(where: { $0.id == activeID }) ?? Self.builtIns[0]
    }

    func setActive(_ id: String) {
        activeID = id
    }

    func add(_ persona: Persona) {
        personas.append(persona)
        persistUserPersonas()
    }

    func update(_ persona: Persona) {
        if let idx = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[idx] = persona
            persistUserPersonas()
        }
    }

    func delete(_ id: String) {
        guard let p = personas.first(where: { $0.id == id }), !p.isBuiltIn else { return }
        personas.removeAll { $0.id == id }
        if activeID == id { activeID = "general" }
        persistUserPersonas()
    }

    private func persistUserPersonas() {
        let custom = personas.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.userPersonasKey)
        }
    }
}
