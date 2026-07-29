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
        let order = ["Language Model", "Vision–Language", "Object Detection",
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
                    VStack(alignment: .leading, spacing: 4) {
                        KCaption(text: "OPEN_SOURCE")
                        KPageTitle(title: "attributions", size: 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    headerSection

                    ForEach(grouped, id: \.category) { group in
                        KSection(title: group.category.lowercased()
                                    .replacingOccurrences(of: " ", with: "_")) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { i, item in
                                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                                AttributionCard(item: item).padding(14)
                            }
                        }
                    }

                    disclosureSection
                }
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .background(LiquidPinkBackdrop())
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundColor(T.bad)
                KMono(text: "thank you to the open-source community",
                       size: 12, weight: .semibold, color: T.ink)
            }
            Text("iOS Local LLM is built on the work of many researchers and engineers who released their models, frameworks, and tools openly. Each is listed below with its license and source.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var disclosureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KCaption(text: "important_license_notes")
                Rectangle().fill(T.rule).frame(height: 1)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                noteRow(glyph: "●", color: T.accent,
                        title: "apple ml research models",
                        body: "FastVLM models are distributed by Apple under the Apple Sample Code License / Apple ML Research license. They may only be used as permitted by that license.")
                Rectangle().fill(T.rule).frame(height: 1)
                noteRow(glyph: "●", color: T.accent,
                        title: "tongyi qianwen license",
                        body: "Qwen models permit commercial use with attribution under the Tongyi Qianwen License. Review the license before any commercial redistribution.")
            }
            .padding(14)
            .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    @ViewBuilder
    private func noteRow(glyph: String, color: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name)
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text(item.license)
                    .font(T.mono(9, .medium))
                    .foregroundColor(licenseColor(item.license))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(licenseColor(item.license).opacity(0.12)))
            }

            KMono(text: "by \(item.author)", size: 10, color: T.ink3)

            Text(item.note)
                .font(T.sans(11.5))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(spacing: 10) {
                if let s = item.sourceURL, let url = URL(string: s) {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                            Text("source").font(T.mono(10))
                        }
                    }
                }
                if let l = item.licenseURL, let url = URL(string: l) {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9))
                            Text("license").font(T.mono(10))
                        }
                    }
                }
                if let p = item.paperURL, let url = URL(string: p) {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 9))
                            Text("paper").font(T.mono(10))
                        }
                    }
                }
            }
            .foregroundColor(T.accent)
            .padding(.top, 4)
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
