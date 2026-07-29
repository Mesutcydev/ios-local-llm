import SwiftUI

// MARK: - KoduComponents
// Reusable UI primitives matching the Kodu Studio design language.
// Every screen in IOSLocalLLM should compose these instead of one-off styling.

// MARK: - Mono label

/// Small monospaced caption. The workhorse text style of the design.
struct KMono: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    var color: Color? = nil
    var tracking: CGFloat = 0
    /// When false, renders in SF-Pro sans instead of monospace. Native iOS
    /// Settings uses sans for plain labels/values; mono is reserved for
    /// genuinely code/technical content (ids, shapes, tok/s). Defaults true
    /// so every existing KMono usage is unchanged.
    var mono: Bool = true

    @Environment(\.koduTheme) private var T

    var body: some View {
        Text(text)
            .font(mono ? T.mono(size, weight) : T.sans(size, weight))
            .foregroundColor(color ?? T.ink2)
            .tracking(tracking)
    }
}

/// Uppercase mono label used as a small caption above values.
/// e.g. `TOK/SEC`, `TOKENS`, `SESSION`
struct KCaption: View {
    let text: String
    var color: Color? = nil
    @Environment(\.koduTheme) private var T

    var body: some View {
        // Eyebrows: sans, bold, uppercase. Neutral ink by default — the
        // uppercase weight + tracking already give them their role, so they
        // don't need to be accent-colored. Callers pass `color:` for the rare
        // intentional accent eyebrow. (Desaturating these app-wide is a big part
        // of the professional, ChatGPT-like restraint.)
        Text(text.uppercased())
            .font(T.sans(11, .bold))
            .foregroundColor(color ?? T.ink3)
            .tracking(0)
    }
}

// MARK: - Status dot (●, ◐, ○)

enum KStatusGlyph: String {
    case ready = "●"        // filled
    case streaming = "◐"    // half
    case remote = "○"       // empty
    case download = "↓"
}

struct KStatusBadge: View {
    let glyph: KStatusGlyph
    let label: String
    let color: Color

    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 4) {
            Text(glyph.rawValue)
            Text(label)
        }
        .font(T.mono(10))
        .foregroundColor(color)
        // The ●/◐/○ glyph carries no meaning to VoiceOver and is
        // indistinguishable to color-blind users — collapse the badge into a
        // single element that announces just the status word.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// MARK: - Tactile Button Style

/// Reusable tactile feedback button style for the Kodu Studio design language.
struct KTactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Icon button (32×32 square)

/// Square 32×32 icon button — used in nav bars, toolbars, composers.
struct KIconButton<Icon: View>: View {
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void = {}
    var size: CGFloat = 32
    var radius: CGFloat = 6

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: size, height: size)
                .kClearGlass(
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous),
                    interactive: true,
                    fallbackFill: T.surface,
                    fallbackStroke: T.rule
                )
        }
        .buttonStyle(KTactileButtonStyle())
    }
}

// MARK: - Primary / Secondary buttons

/// Primary action button — solid ink fill, white text.
struct KPrimaryButton: View {
    let label: String
    var systemImage: String? = nil
    var trailing: String? = nil      // e.g. "↵" mono hint on the right
    var action: () -> Void = {}
    var disabled: Bool = false

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let sys = systemImage {
                    Image(systemName: sys)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(label)
                    .font(T.sans(15, .medium))
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(T.mono(10))
                        .foregroundColor(T.ink4)
                }
            }
            .foregroundColor(T.accentStrong)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                tint: T.accentStrong,
                interactive: true,
                fallbackFill: T.accentStrong
            )
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(KTactileButtonStyle())
        .disabled(disabled)
    }
}

/// Secondary action — surface fill with a 1px rule border.
struct KSecondaryButton: View {
    let label: String
    var systemImage: String? = nil
    var trailing: String? = "→"
    var destructive: Bool = false
    var action: () -> Void = {}

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let sys = systemImage {
                    Image(systemName: sys)
                        .font(.system(size: 13))
                        .foregroundColor(destructive ? T.bad : T.ink)
                }
                Text(label)
                    .font(T.sans(13.5))
                    .foregroundColor(destructive ? T.bad : T.ink)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                interactive: true,
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
        .buttonStyle(KTactileButtonStyle())
    }
}

// MARK: - Section
// A grouped settings/info block: small mono caption + a hairline rule
// extending to the right, then a bordered surface container.

struct KSection<Content: View>: View {
    let title: String
    var tinted: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                KCaption(text: title.replacingOccurrences(of: "_", with: " "))
                Rectangle().fill(T.rule).frame(height: 1)
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: tinted ? T.accentSofter : nil,
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }
}

// MARK: - Collapsible section
//
// Same chrome as KSection, but the header doubles as a tap target that
// expands/collapses an inline body. Used for status panels and power-user
// settings that don't need to occupy a screen-height of rows by default.
// State is local — the parent doesn't need to manage it unless it wants
// to control multiple sections (in which case use `expanded:` binding).

struct KCollapsibleSection<Content: View>: View {
    let title: String
    var tinted: Bool = false
    var defaultExpanded: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.koduTheme) private var T
    @State private var localExpanded: Bool

    init(title: String,
         tinted: Bool = false,
         defaultExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.tinted = tinted
        self.defaultExpanded = defaultExpanded
        self.content = content
        _localExpanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                KCaption(text: title.replacingOccurrences(of: "_", with: " "))
                Rectangle().fill(T.rule).frame(height: 1)
            }
            .padding(.bottom, 8)

            Button {
                withAnimation(.easeInOut(duration: 0.28)) {
                    localExpanded.toggle()
                }
                HapticManager.impact(.light)
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(title.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(T.sans(15, .semibold)).foregroundColor(T.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(T.ink4)
                            .rotationEffect(.degrees(localExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)

                    if localExpanded {
                        Rectangle().fill(T.rule).frame(height: 1)
                        VStack(spacing: 0) { content() }
                    }
                }
            }
            .buttonStyle(.plain)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: tinted ? T.accentSofter : nil,
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }
}

/// One row inside a KSection. `last: true` removes the bottom divider.
struct KRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing
    var last: Bool = false
    var stack: Bool = false

    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if stack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label).font(T.sans(15)).foregroundColor(T.ink)
                        trailing()
                    }
                } else {
                    HStack(spacing: 12) {
                        Text(label).font(T.sans(15)).foregroundColor(T.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        trailing()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if !last {
                Rectangle().fill(T.rule).frame(height: 1)
            }
        }
    }
}

// MARK: - Spec table
// `[(key, value)]` rendered as a bordered card with mono key / mono value rows.

struct KSpecTable: View {
    let rows: [(String, String)]
    var keyWidth: CGFloat = 110

    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                HStack(spacing: 12) {
                    KMono(text: row.0, size: 11, color: T.ink3)
                        .frame(width: keyWidth, alignment: .leading)
                    KMono(text: row.1, size: 11, color: T.ink)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: 8),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }
}

// MARK: - Telemetry strip
// Small bordered strip with stacked CAPTION / value pairs.

struct KTelemetryItem: Identifiable {
    let id = UUID()
    let caption: String
    let value: String
    var color: Color? = nil
    var align: HorizontalAlignment = .leading
}

struct KTelemetryStrip: View {
    let items: [KTelemetryItem]

    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: item.align, spacing: 1) {
                    KCaption(text: item.caption)
                    Text(item.value)
                        .font(T.mono(13, .semibold))
                        .foregroundColor(item.color ?? T.ink)
                }
                .frame(maxWidth: .infinity, alignment: alignment(item.align))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: 6),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }

    private func alignment(_ h: HorizontalAlignment) -> Alignment {
        switch h {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }
}

// MARK: - Tag / chip

/// Small bordered tag — `qwen3`, `mlx`, `code`, etc.
struct KTag: View {
    let text: String
    var size: CGFloat = 10
    @Environment(\.koduTheme) private var T

    var body: some View {
        Text(text)
            .font(T.mono(size))
            .foregroundColor(T.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 4),
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
    }
}

// MARK: - Wrapping row

/// Places compact metadata views left-to-right and wraps them onto additional
/// lines when the available width is exhausted. Unlike a horizontal
/// ScrollView, every item remains visible inside its card on narrow iPhones.
struct KFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let result = layout(subviews: subviews, availableWidth: availableWidth)
        let width = proposal.width ?? result.contentWidth
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func layout(
        subviews: Subviews,
        availableWidth: CGFloat
    ) -> (contentWidth: CGFloat, height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > availableWidth {
                contentWidth = max(contentWidth, x - horizontalSpacing)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        contentWidth = max(contentWidth, max(0, x - horizontalSpacing))
        return (contentWidth, subviews.isEmpty ? 0 : y + rowHeight)
    }
}

/// ACTIVE pill — accent text on accentSoft fill.
struct KActivePill: View {
    let text: String
    @Environment(\.koduTheme) private var T
    var body: some View {
        Text(text.uppercased())
            .font(T.mono(9, .semibold))
            .tracking(0)
            .foregroundColor(T.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 3),
                tint: T.accentSoft
            )
    }
}

// MARK: - Compatibility / memory chip
//
// One-line capsule (glyph + short word) for a fit/compat verdict — replaces
// the multi-line tinted warning boxes that used to stack several-deep on a
// card. The long reason rides along as `detail` and is revealed on tap
// (an alert) instead of consuming vertical space inline.

struct KCompatChip: View {
    enum Level {
        case ok, tight, blocked
        var glyph: String {
            switch self {
            case .ok:      return "checkmark.circle.fill"
            case .tight:   return "exclamationmark.triangle.fill"
            case .blocked: return "xmark.octagon.fill"
            }
        }
    }
    let level: Level
    let text: String
    var detail: String? = nil

    @Environment(\.koduTheme) private var T
    @State private var showDetail = false

    private var color: Color {
        switch level {
        case .ok:      return T.good
        case .tight:   return T.warn
        case .blocked: return T.bad
        }
    }

    var body: some View {
        Button {
            guard detail != nil else { return }
            showDetail = true
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: level.glyph).font(.system(size: 9, weight: .bold))
                Text(text).font(T.mono(10, .medium))
                if detail != nil {
                    Image(systemName: "info.circle").font(.system(size: 8, weight: .semibold)).opacity(0.65)
                }
            }
            .foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .kClearGlass(in: Capsule(), tint: color.opacity(T.isDark ? 0.16 : 0.10))
        }
        .buttonStyle(.plain)
        .disabled(detail == nil)
        .alert(text, isPresented: $showDetail) {
            Button("OK", role: .cancel) {}
        } message: {
            if let detail { Text(detail) }
        }
    }
}

// MARK: - Inline disclosure rows ("More models", "Advanced")
//
// A collapsed group of rows behind a tappable header, for use INSIDE a
// KSection card (KCollapsibleSection is a whole standalone section instead).
// Keeps a long tail of options or power-user settings one tap away without
// removing anything.

struct KDisclosureRows<Content: View>: View {
    let title: String
    var count: Int? = nil
    var startsOpen: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.koduTheme) private var T
    @State private var open: Bool

    init(title: String, count: Int? = nil, startsOpen: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.startsOpen = startsOpen
        self.content = content
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { open.toggle() }
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: 8) {
                    Text(count.map { "\(title) (\($0))" } ?? title)
                        .font(T.sans(13, .medium)).foregroundColor(T.ink2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(T.ink4)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open { content() }
        }
    }
}

// MARK: - Wordmark (kodu/IOSLocalLLM monogram)

struct KWordmark: View {
    var name: String = "ioslocalllm"
    var monogram: String = "k"
    /// Asset name of an image logo; when set it replaces the letter monogram.
    var logoAsset: String? = nil
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 8) {
            if let logoAsset {
                Image(logoAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(monogram)
                    .font(T.mono(14, .semibold))
                    .foregroundColor(T.bg)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
            }
            Text(name)
                .font(T.display(17, .semibold))
                .tracking(0)
                .foregroundColor(T.ink)
        }
    }
}

// MARK: - Page title

/// Large display title used at the top of full screens.
/// e.g. "Models", "Settings"
struct KPageTitle: View {
    let title: String
    var size: CGFloat = 30
    @Environment(\.koduTheme) private var T

    var body: some View {
        Text(title)
            .font(T.display(size, .semibold))
            .tracking(0)
            .foregroundColor(T.ink)
            .lineLimit(1)
    }
}

// MARK: - Toggle

struct KToggle: View {
    @Binding var isOn: Bool
    @Environment(\.koduTheme) private var T

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isOn ? T.accent : T.ink4.opacity(0.5))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(T.surface)
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        // This is a custom switch, not a SwiftUI Toggle — without these traits
        // VoiceOver announces a bare "button". `.isToggle` + on/off value makes
        // it read as "<label>, switch, on" like a native control. The label
        // comes from the enclosing KRow / settings context.
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Active row marker (2px left accent stripe)

/// Wrap any row to give it the "active model" 2px accent stripe on the left.
struct KActiveRowMarker<Content: View>: View {
    let isActive: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.koduTheme) private var T

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .background(isActive ? T.accentSofter : Color.clear)
            if isActive {
                Rectangle()
                    .fill(T.accent)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - KModelName
//
// Smart label for long HuggingFace-style model names. The problem:
//   "lmstudio-community/Qwen3-VL-8B-Instruct-MLX-4bit"
// is 48 chars and absolutely will not fit on one line at 13-17pt in a
// picker row. Plain `.lineLimit(1).truncationMode(.middle)` keeps it
// on one line but eats the most informative parts — the user can no
// longer tell "4bit" from "8bit" or "Instruct" from "Coder".
//
// Strategy (in priority order):
//   1. Insert zero-width spaces after `-` `_` `/` and around digits.
//      This is the cheapest fix: it gives the layout engine sanctioned
//      break-points, so a name that's just barely too long now wraps
//      cleanly at "Qwen3‑VL‑8B / Instruct‑MLX‑4bit" instead of
//      truncating to "Qwen3-VL-8B-Instruct…".
//   2. `.minimumScaleFactor(0.82)` so a borderline-long name compresses
//      a few points before committing to a wrap. Below 0.82 the text
//      becomes unreadable at picker-row sizes.
//   3. `.lineLimit(maxLines)` (default 2) with `.truncationMode(.tail)`
//      as the last resort. Tail-truncation here is intentional: by the
//      time we've wrapped to 2 lines AND scaled, anything still
//      overflowing is genuinely too long to render in this surface and
//      we'd rather drop the trailing variant tag than the family name.
//
// Usage:
//   KModelName("ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
//              font: T.display(17, .semibold), color: T.ink)
//   KModelName(model.displayName, font: T.mono(13, .semibold))
//
// For surfaces where vertical wrap is unsafe (toolbar pills, debug
// overlays, marquee status bars), see `MarqueeText` below.

struct KModelName: View {
    let raw: String
    var font: Font
    var color: Color = .primary
    var maxLines: Int = 2
    var minScale: CGFloat = 0.82
    var alignment: TextAlignment = .leading

    init(_ raw: String,
         font: Font,
         color: Color = .primary,
         maxLines: Int = 2,
         minScale: CGFloat = 0.82,
         alignment: TextAlignment = .leading) {
        self.raw = raw
        self.font = font
        self.color = color
        self.maxLines = maxLines
        self.minScale = minScale
        self.alignment = alignment
    }

    var body: some View {
        Text(Self.softBreakable(raw))
            .font(font)
            .foregroundColor(color)
            .multilineTextAlignment(alignment)
            .lineLimit(maxLines)
            .minimumScaleFactor(minScale)
            .truncationMode(.tail)
            .allowsTightening(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Sprinkle zero-width spaces around separator chars and digit/letter
    /// boundaries so the layout engine has legal break-points without
    /// changing the visible text. The Unicode `\u{200B}` (ZWSP) is
    /// invisible AND copy-safe — round-trips through the clipboard look
    /// identical to the original string for the user.
    private static func softBreakable(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        var prev: Character = " "
        for ch in s {
            // Allow a break BEFORE `/`, `-`, `_`, `.` so e.g.
            // "org/Model-Name" can wrap as "org / Model‑Name".
            if "/-_.".contains(ch) {
                out.append("\u{200B}")
                out.append(ch)
                // ALSO allow a break AFTER, in case the suffix is the
                // longer half (common for "8B-Instruct-MLX-4bit").
                prev = ch
                continue
            }
            // Allow a break between a digit and a following letter
            // ("8B" → "8" + ZWSP + "B"-letters that follow) so size
            // codes can wrap onto their own line if the row is narrow.
            if prev.isNumber, ch.isLetter, prev != " " {
                out.append("\u{200B}")
            }
            out.append(ch)
            prev = ch
        }
        return out
    }
}

// MARK: - MarqueeText
//
// Single-line auto-scrolling label for places where vertical wrap is
// impossible (toolbar status pills, debug-overlay rows, capture caption
// header). Measures the text against the available width; if the text
// fits, renders statically. If it doesn't, it slides leftward at a
// readable speed (~30 pt/sec) with a fade-out edge mask on both sides.
//
// Wakes up only when the text actually overflows — no animation cost
// for short names. Pauses on tap so users can read mid-marquee.

struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var speed: CGFloat = 30                 // points per second
    var spacing: CGFloat = 32               // gap between repeating runs

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var paused = false

    var body: some View {
        GeometryReader { geo in
            let needsScroll = textWidth > geo.size.width
            HStack(spacing: spacing) {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .fixedSize()
                    .background(
                        // Measure the rendered width once, off the
                        // GeometryReader, so we can decide whether to
                        // animate. preferenceKey is cheaper than another
                        // GeometryReader nested inside this one.
                        GeometryReader { tg in
                            Color.clear.preference(
                                key: MarqueeWidthKey.self, value: tg.size.width
                            )
                        }
                    )
                if needsScroll {
                    // Second copy of the label so the slide is seamless:
                    // when the first copy scrolls off the leading edge,
                    // the second is already in position to take over.
                    Text(text)
                        .font(font)
                        .foregroundColor(color)
                        .fixedSize()
                }
            }
            .offset(x: offset)
            .onPreferenceChange(MarqueeWidthKey.self) { w in
                textWidth = w
                containerWidth = geo.size.width
                restart()
            }
            .onChange(of: geo.size.width) { _, new in
                containerWidth = new
                restart()
            }
            .mask(
                // Soft fade at both edges so the loop point doesn't read
                // as a jarring snap. Plain solid fill (no shimmer) since
                // this is a "the text is too long to show" affordance,
                // not a loading state.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                paused.toggle()
                if paused {
                    withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                } else {
                    restart()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: lineHeight())
    }

    private func restart() {
        guard !paused, textWidth > containerWidth, textWidth > 0 else {
            offset = 0
            return
        }
        offset = 0
        let distance = textWidth + spacing
        let duration = Double(distance / speed)
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }

    /// Rough single-line height — Marquee is single-line by definition
    /// so we can match the font's natural lineHeight via a hidden Text
    /// measurement. The actual character glyphs are rendered above.
    private func lineHeight() -> CGFloat {
        // Heuristic for the common font sizes used in IOSLocalLLM. A
        // GeometryReader inside the body would be more precise but
        // adds a layout pass we don't need — the values below match
        // T.mono / T.sans / T.display rendered heights to within a
        // pixel.
        20
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
