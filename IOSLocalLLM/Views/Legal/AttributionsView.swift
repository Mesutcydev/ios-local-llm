import SwiftUI

// MARK: - AttributionsView
// Lists every third-party model, dataset, and framework used by the app,
// with author, license, source link, and citation. Required for App Store
// compliance and for license obligations (Apache-2.0, MIT, Apple Sample
// Code License, Tongyi Qianwen, AGPL-3.0, etc.).

struct AttributionsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    private var grouped: [(category: String, items: [Attribution])] {
        let dict = Dictionary(grouping: LegalDocuments.attributions, by: { $0.category })
        let order = ["Language Model", "Vision–Language", "Image Generation", "Object Detection",
                     "Text-to-Speech", "Framework", "Service"]
        return order.compactMap { cat in
            guard let items = dict[cat] else { return nil }
            return (cat, items)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        KCaption(text: "OPEN_SOURCE")
                        KPageTitle(title: "attributions", size: 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.m)
                    .padding(.top, Space.xxs)

                    headerSection

                    if let licenses = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt") {
                        ShareLink("Full licenses and notices", item: licenses)
                            .padding(Space.m)
                            .accessibilityIdentifier("thirdPartyLicenseNotices")
                    }

                    ForEach(grouped, id: \.category) { group in
                        KSection(title: group.category.lowercased()
                                    .replacingOccurrences(of: " ", with: "_")) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { i, item in
                                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                                AttributionCard(item: item).padding(Space.m)
                            }
                        }
                    }

                    disclosureSection
                }
                .padding(.bottom, Space.l)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .background(LiquidPinkBackdrop())
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "heart.fill")
                    .font(.system(.caption2))
                    .foregroundColor(T.bad)
                KMono(text: "thank you to the open-source community",
                       size: 12, weight: .semibold, color: T.ink)
            }
            Text("iOS Local LLM is built on the work of many researchers and engineers who released their models, frameworks, and tools openly. Each is listed below with its license and source.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: Radius.card, fallbackFill: T.surface)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.m)
    }

    private var disclosureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                KCaption(text: "important_license_notes")
                Rectangle().fill(T.rule).frame(height: 1)
            }
            .padding(.bottom, Space.s)

            VStack(alignment: .leading, spacing: Space.s) {
                noteRow(glyph: "●", color: T.accent,
                        title: "apple ml research models",
                        body: "The Apple Sample Code License covers the adapted source code. FastVLM research weights and derived encoders are unavailable in the consumer app.")
                Rectangle().fill(T.rule).frame(height: 1)
                noteRow(glyph: "●", color: T.accent,
                        title: "downloaded model licenses",
                        body: "Licenses vary by model and version, including within the Qwen family. Read the license at the exact download source before use or redistribution.")
            }
            .padding(Space.m)
            .kGlass(cornerRadius: Radius.card, fallbackFill: T.surface)
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.m)
    }

    @ViewBuilder
    private func noteRow(glyph: String, color: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Text(glyph)
                    .font(T.mono(10))
                    .foregroundColor(color)
                KMono(text: title, size: 11, weight: .semibold, color: T.ink)
            }
            Text(body)
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - AttributionCard

struct AttributionCard: View {
    let item: Attribution
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(item.name)
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text(item.license)
                    .font(T.mono(9, .medium))
                    .foregroundColor(licenseColor(item.license))
                    .padding(.horizontal, Space.xs).padding(.vertical, Space.hair)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(licenseColor(item.license).opacity(0.12)))
            }

            KMono(text: "by \(item.author)", size: 10, color: T.ink3)

            Text(item.note)
                .font(T.sans(11.5))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.hair)

            HStack(spacing: Space.s) {
                if let s = item.sourceURL, let url = URL(string: s) {
                    Link(destination: url) {
                        HStack(spacing: Space.xxs) {
                            Image(systemName: "link")
                                .font(.system(.caption2))
                            Text("source").font(T.mono(10))
                        }
                    }
                }
                if let l = item.licenseURL, let url = URL(string: l) {
                    Link(destination: url) {
                        HStack(spacing: Space.xxs) {
                            Image(systemName: "doc.text")
                                .font(.system(.caption2))
                            Text("license").font(T.mono(10))
                        }
                    }
                }
                if let p = item.paperURL, let url = URL(string: p) {
                    Link(destination: url) {
                        HStack(spacing: Space.xxs) {
                            Image(systemName: "doc.richtext")
                                .font(.system(.caption2))
                            Text("paper").font(T.mono(10))
                        }
                    }
                }
            }
            .foregroundColor(T.accent)
            .padding(.top, Space.xxs)
        }
    }

    private func licenseColor(_ name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("agpl")   { return T.warn }
        if lower.contains("mit")    { return T.good }
        if lower.contains("apache") { return T.good }
        if lower.contains("tongyi") { return T.accent }
        if lower.contains("apple")  { return T.accent }
        return T.ink3
    }
}
