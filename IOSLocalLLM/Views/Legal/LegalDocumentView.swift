import SwiftUI

// MARK: - LegalDocumentView
// Renders any of the long-form legal texts (Privacy, EULA, AI Disclaimer)
// with consistent typography and an optional "I Agree" action button.

struct LegalDocumentView: View {

    let title: String
    let markdown: String
    let externalURL: String?
    /// When non-nil, shown as a primary action button at the bottom.
    let primaryAction: (label: String, run: () -> Void)?
    /// When non-nil, shown as a secondary destructive action.
    let secondaryAction: (label: String, run: () -> Void)?
    /// Consent mode: when non-nil, an "I have read this" confirm button is
    /// shown that ENABLES only after the user scrolls to the end, and tapping
    /// it runs this closure + dismisses. Used by the first-launch legal gate so
    /// "opened the sheet" no longer counts as "read" (the recorded acceptance
    /// reflects genuine review).
    let onReadConfirmed: (() -> Void)?

    init(
        title: String,
        markdown: String,
        externalURL: String? = nil,
        primaryAction: (label: String, run: () -> Void)? = nil,
        secondaryAction: (label: String, run: () -> Void)? = nil,
        onReadConfirmed: (() -> Void)? = nil
    ) {
        self.title = title
        self.markdown = markdown
        self.externalURL = externalURL
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.onReadConfirmed = onReadConfirmed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    /// Flips true once the bottom sentinel scrolls into view (or immediately
    /// for documents short enough to fit without scrolling).
    @State private var scrolledToEnd = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    // LazyVStack so the bottom sentinel's onAppear fires only
                    // when it actually scrolls into view (a plain VStack would
                    // fire every child's onAppear up front, defeating the gate).
                    LazyVStack(spacing: 0) {
                        MarkdownTextView(markdown: markdown)
                            .padding(.horizontal, 18)
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                        Color.clear
                            .frame(height: 1)
                            .onAppear { scrolledToEnd = true }
                    }
                }

                if primaryAction != nil || secondaryAction != nil || onReadConfirmed != nil {
                    Rectangle().fill(T.rule).frame(height: 1)
                    actionBar
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .kClearGlass(in: Rectangle(), fallbackFill: T.surface)
                }
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(title.lowercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let urlStr = externalURL, let url = URL(string: urlStr) {
                        Link(destination: url) {
                            Image(systemName: "safari").foregroundColor(T.accent)
                        }
                    } else {
                        Button("Done") { dismiss() }
                            .foregroundColor(T.ink)
                    }
                }
                #if targetEnvironment(macCatalyst)
                // Mac Catalyst sheets can't be swipe-dismissed. The URL-bearing
                // sheets (Privacy, EULA) otherwise show only the Safari link and
                // would be impossible to close — which blocks the first-launch
                // legal gate. Add an explicit Done on Mac for those. (No-URL
                // sheets already have Done in the trailing slot.) iOS unchanged.
                if externalURL != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                            .foregroundColor(T.ink)
                    }
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            if let confirm = onReadConfirmed {
                Button {
                    HapticManager.impact(.medium)
                    confirm()
                    dismiss()
                } label: {
                    Text(scrolledToEnd ? "i have read this" : "scroll to the end to continue")
                        .font(T.mono(13, .semibold))
                        .foregroundColor(scrolledToEnd ? T.bg : T.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(scrolledToEnd ? T.ink : T.surface2))
                }
                .buttonStyle(.plain)
                .disabled(!scrolledToEnd)
            }
            if let secondary = secondaryAction {
                Button(role: .destructive) {
                    secondary.run()
                } label: {
                    Text(secondary.label.lowercased())
                        .font(T.mono(13, .semibold))
                        .foregroundColor(T.bad)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(T.bad.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            if let primary = primaryAction {
                Button {
                    HapticManager.impact(.medium)
                    primary.run()
                } label: {
                    Text(primary.label.lowercased())
                        .font(T.mono(13, .semibold))
                        .foregroundColor(T.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(T.ink))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
