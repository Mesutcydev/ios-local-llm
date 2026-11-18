import SwiftUI

// MARK: - WebActivityLogView
// Displays the on-device record of every web request the Web Tool made.

struct WebActivityLogView: View {
    @ObservedObject private var log = WebActivityLogger.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if log.entries.isEmpty { emptyState }
                    else {
                        ForEach(log.entries) { entry in
                            row(entry)
                            Rectangle().fill(T.rule).frame(height: 1)
                        }
                    }
                }
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle("Web Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.foregroundColor(T.ink)
                }
                if !log.entries.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            log.clear()
                        } label: {
                            Text("Clear").foregroundColor(T.bad)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "tray").font(.system(.title)).foregroundColor(T.ink3)
            KMono(text: "no web activity yet", size: 12, color: T.ink2)
            KMono(text: "every request the Web Tool makes lands here", size: 10, color: T.ink3)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ e: WebActivityLogEntry) -> some View {
        let color: Color = {
            switch e.kind {
            case .error, .injectionFlagged, .rateLimited: return T.warn
            case .search: return T.accent
            case .fetch: return T.good
            }
        }()
        let label: String = {
            switch e.kind {
            case .search: return "search"
            case .fetch: return "fetch"
            case .injectionFlagged: return "redacted"
            case .rateLimited: return "rate-limited"
            case .error: return "error"
            }
        }()
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(label.uppercased())
                    .font(T.mono(9, .semibold))
                    .tracking(TextScale.capsTracking)
                    .foregroundColor(color)
                if let p = e.provider {
                    Text("· \(p.rawValue)")
                        .font(T.mono(9))
                        .foregroundColor(T.ink3)
                }
                if e.fromCache {
                    Text("· cache")
                        .font(T.mono(9))
                        .foregroundColor(T.ink3)
                }
                Spacer()
                Text(e.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(T.mono(9))
                    .foregroundColor(T.ink3)
            }
            Text(e.queryOrURL)
                .font(T.mono(11))
                .foregroundColor(T.ink)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Space.s) {
                if let s = e.statusCode { KMono(text: "\(s)", size: 9, color: T.ink3) }
                if let b = e.bytesIn { KMono(text: "\(b)B", size: 9, color: T.ink3) }
                if let d = e.durationMs { KMono(text: "\(d)ms", size: 9, color: T.ink3) }
            }
            if let n = e.note {
                Text(n)
                    .font(T.sans(10))
                    .foregroundColor(T.ink3)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }
}
