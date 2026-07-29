import SwiftUI

// MARK: - ArenaLeaderboardCard
//
// Shared standings card rendered under both A/B compare surfaces (text in
// CompareView, images in VisualModelComparisonView). Reads the persisted
// per-device Elo ladder from ModelArenaStore for one lane and lists models
// strongest-first with their rating and W-L-T tally. This is the payoff of
// recording a winner — the ranking the user is building shows up in the
// same place they vote.

struct ArenaLeaderboardCard: View {

    let lane: ModelArenaStore.Lane
    /// Section title — defaults to "standings" but callers can localize.
    var title: String = "standings"

    @ObservedObject private var arena = ModelArenaStore.shared
    @Environment(\.koduTheme) private var T
    @State private var showResetConfirm = false

    private var rows: [ModelArenaStore.Record] { arena.leaderboard(lane: lane) }

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            KSection(title: title) {
                VStack(spacing: 0) {
                    headerRow
                    Rectangle().fill(T.rule).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                        standingRow(rank: i + 1, record: r)
                    }
                    Rectangle().fill(T.rule).frame(height: 1)
                    footer
                }
            }
        }
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#").font(T.mono(9, .semibold)).foregroundColor(T.ink3)
                .frame(width: 24, alignment: .leading)
            Text("MODEL").font(T.mono(9, .semibold)).tracking(0.5)
                .foregroundColor(T.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("ELO").font(T.mono(9, .semibold)).foregroundColor(T.ink3)
                .frame(width: 44, alignment: .trailing)
            Text("W-L-T").font(T.mono(9, .semibold)).foregroundColor(T.ink3)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func standingRow(rank: Int, record r: ModelArenaStore.Record) -> some View {
        HStack(spacing: 0) {
            Text("\(rank)")
                .font(T.mono(11, .semibold))
                .foregroundColor(rank == 1 ? T.accent : T.ink3)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.displayName)
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: "%.0f%% win · %d games", r.winRate * 100, r.games))
                    .font(T.mono(8.5))
                    .foregroundColor(T.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.0f", r.rating))
                .font(T.mono(11, .semibold))
                .foregroundColor(T.ink)
                .frame(width: 44, alignment: .trailing)
            Text("\(r.wins)-\(r.losses)-\(r.ties)")
                .font(T.mono(10))
                .foregroundColor(T.ink2)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        Button(role: .destructive) {
            showResetConfirm = true
        } label: {
            Text("reset standings")
                .font(T.mono(10, .semibold))
                .foregroundColor(T.bad)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Reset \(lane.rawValue) standings?",
                            isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { arena.reset(lane: lane) }
        } message: {
            Text("Clears Elo ratings and win/loss records for \(lane.rawValue) models on this device.")
        }
    }

    private var emptyState: some View {
        KSection(title: title) {
            HStack(spacing: 8) {
                Image(systemName: "trophy")
                    .font(.system(size: 12))
                    .foregroundColor(T.ink3)
                Text("no votes yet — run a comparison and pick a winner to start the ladder")
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(14)
        }
    }
}
