import SwiftUI

enum AppLayout {
    static let readingWidth: CGFloat = 760
    static let dashboardWidth: CGFloat = 1_040
}

/// Keep the system navigation bar available for its sidebar control on wide
/// layouts. Compact roots already have their own content headings.
struct AdaptiveTabNavigation<Content: View>: View {
    let content: Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(horizontalSizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        }
    }
}

/// Let the system move the same tabs between the outer display's bar and the
/// inner display's sidebar. Selection and feature services stay in ContentView.
struct AdaptiveTabPlacement: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.defaultTabBarPlacement(.sidebar)
        } else {
            content
        }
    }
}

/// The padded container keeps its full width while its controls occupy the
/// largest region clear of an active vertical fold. Safe areas remain owned by
/// SwiftUI, including the asymmetric space reserved for vertical system bars.
private struct DisplayDivisionAvoidance: ViewModifier {
    @State private var insets = DisplayDivisionInsets()

    @ViewBuilder
    func body(content: Content) -> some View {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            content
                .frame(maxWidth: AppLayout.readingWidth)
                .frame(maxWidth: .infinity)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .onGeometryChange(for: DisplayDivisionInsets.self) { proxy in
                    DisplayDivisionInsets.resolve(
                        in: CGRect(origin: .zero, size: proxy.size),
                        avoiding: proxy.reservedRegions(kind: .division)
                            .filter(\.isActive).map(\.frame)
                    )
                } action: { insets = $0 }
        } else {
            content
                .frame(maxWidth: AppLayout.readingWidth)
                .frame(maxWidth: .infinity)
        }
        #else
        content
            .frame(maxWidth: AppLayout.readingWidth)
            .frame(maxWidth: .infinity)
        #endif
    }
}

extension View {
    func avoidingDisplayDivision() -> some View {
        modifier(DisplayDivisionAvoidance())
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func adaptingToolbarAxis() -> some ToolbarContent {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            self.axisBehavior(.verticalPreferred)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ToolbarContentBuilder
    func primaryToolbarAction() -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            self.visibilityPriority(.high)
        } else {
            self
        }
    }
}
