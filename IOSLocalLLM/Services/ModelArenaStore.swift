import Foundation

// MARK: - ModelArenaStore
//
// Persisted, on-device "arena" for head-to-head model votes. The A/B
// compare surfaces (CompareView for text, VisualModelComparisonView for
// images) let the user run one prompt against two models and pick a
// winner. Before this store the verdict evaporated the moment the sheet
// closed — the compare header literally said "pick a winner" with no way
// to record one. This makes the vote durable: every match updates an Elo
// rating and a win/loss/tie tally, producing a per-device leaderboard
// that's the thing people actually open a model-testing app to build.
//
// Why Elo and not just win-rate: win-rate alone over-rewards a model that
// only ever faced weak opponents. Elo discounts a win against a model the
// user already rates low and rewards an upset, so the ranking stays honest
// as the user pits stronger models against each other over time. Win/loss
// counts are kept alongside for a plain-language summary.
//
// Lanes keep modalities separate. Comparing a text LLM's Elo against a
// vision VLM's Elo is meaningless — they never play each other — so each
// lane is an independent rating pool with its own leaderboard.

@MainActor
final class ModelArenaStore: ObservableObject {

    static let shared = ModelArenaStore()

    // MARK: - Types

    /// Which rating pool a match belongs to. Text models and vision models
    /// never face each other, so they rank independently.
    enum Lane: String, Codable, CaseIterable {
        case text
        case vision
    }

    /// Outcome of a single head-to-head, from model A's perspective.
    enum Outcome {
        case aWins
        case bWins
        case tie
    }

    /// One model's standing within a lane.
    struct Record: Codable, Identifiable, Hashable {
        let lane: Lane
        let modelID: String        // AssistantModel.id (text) or repoID (vision)
        var displayName: String
        var rating: Double          // Elo; everyone starts at `startRating`
        var wins: Int
        var losses: Int
        var ties: Int

        // Identity is lane-scoped so the same repoID can appear in both
        // lanes (rare, but a multimodal model could be benched either way).
        var id: String { "\(lane.rawValue):\(modelID)" }

        var games: Int { wins + losses + ties }
        var winRate: Double { games == 0 ? 0 : Double(wins) / Double(games) }
    }

    // MARK: - Tunables

    /// Elo starting point. 1000 is conventional for a fresh ladder.
    static let startRating: Double = 1000
    /// K-factor — how much a single result moves a rating. 32 is the
    /// classic chess value; high enough that a handful of votes produces a
    /// visible ranking, low enough that one upset doesn't whipsaw the board.
    private static let kFactor: Double = 32

    // MARK: - State

    /// All records keyed by `Record.id` ("lane:modelID").
    @Published private(set) var records: [String: Record] = [:]

    private let storageKey = "codelens.modelarena.records.v1"

    private init() { load() }

    // MARK: - Recording a match

    /// Record one head-to-head and update both models' Elo + tallies.
    /// `a` and `b` are `(id, displayName)` pairs; display names are kept
    /// fresh on every call so a renamed/re-quantized entry shows its
    /// current label on the leaderboard.
    func record(
        lane: Lane,
        a: (id: String, name: String),
        b: (id: String, name: String),
        outcome: Outcome
    ) {
        guard a.id != b.id else { return }   // a model can't fight itself

        var ra = records[key(lane, a.id)]
            ?? Record(lane: lane, modelID: a.id, displayName: a.name,
                      rating: Self.startRating, wins: 0, losses: 0, ties: 0)
        var rb = records[key(lane, b.id)]
            ?? Record(lane: lane, modelID: b.id, displayName: b.name,
                      rating: Self.startRating, wins: 0, losses: 0, ties: 0)

        ra.displayName = a.name
        rb.displayName = b.name

        // Expected scores from current ratings.
        let ea = 1.0 / (1.0 + pow(10.0, (rb.rating - ra.rating) / 400.0))
        let eb = 1.0 - ea

        let (sa, sb): (Double, Double)
        switch outcome {
        case .aWins: sa = 1.0; sb = 0.0; ra.wins += 1;  rb.losses += 1
        case .bWins: sa = 0.0; sb = 1.0; ra.losses += 1; rb.wins += 1
        case .tie:   sa = 0.5; sb = 0.5; ra.ties += 1;   rb.ties += 1
        }

        ra.rating += Self.kFactor * (sa - ea)
        rb.rating += Self.kFactor * (sb - eb)

        records[ra.id] = ra
        records[rb.id] = rb
        save()
    }

    // MARK: - Reading

    /// Leaderboard for a lane, strongest first. Ties on rating break by
    /// games played (more-tested models rank above barely-tested ones).
    func leaderboard(lane: Lane) -> [Record] {
        records.values
            .filter { $0.lane == lane }
            .sorted {
                $0.rating != $1.rating ? $0.rating > $1.rating
                                       : $0.games > $1.games
            }
    }

    /// Current record for a model in a lane, if it has played at least once.
    func record(lane: Lane, modelID: String) -> Record? {
        records[key(lane, modelID)]
    }

    /// Total matches played in a lane (wins+losses counted once per match).
    func matchCount(lane: Lane) -> Int {
        let r = records.values.filter { $0.lane == lane }
        // Every match increments two records, so sum games and halve.
        return r.reduce(0) { $0 + $1.games } / 2
    }

    // MARK: - Mutating

    /// Wipe a single lane (or everything when `lane` is nil). Surfaced as a
    /// "reset standings" affordance under each leaderboard.
    func reset(lane: Lane? = nil) {
        if let lane {
            records = records.filter { $0.value.lane != lane }
        } else {
            records = [:]
        }
        save()
    }

    // MARK: - Persistence

    private func key(_ lane: Lane, _ modelID: String) -> String {
        "\(lane.rawValue):\(modelID)"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
