import SwiftUI

// MARK: - CodePanelView

struct CodePanelView: View {
    @Binding var code: String
    let language: String
    @State private var copyFeedback = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    SyntaxHighlightedText(code: code, language: language)
                        .padding()
                }
                .background(Color(red: 0.06, green: 0.06, blue: 0.09))

                Button {
                    UIPasteboard.general.string = code
                    HapticManager.impact(.light)
                    withAnimation(.spring(duration: 0.2)) { copyFeedback = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copyFeedback = false }
                    }
                } label: {
                    Label(
                        copyFeedback ? "Copied!" : "Copy",
                        systemImage: copyFeedback ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(copyFeedback ? Color.green : Color.blue))
                }
                .padding()
            }
            .navigationTitle("\(language) Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - SyntaxHighlightedText
// Multi-pass highlighter: strings first (to avoid false keyword matches inside strings),
// then comments, then keywords, then numbers, then type names.

struct SyntaxHighlightedText: View {
    let code: String
    let language: String

    var body: some View {
        Text(highlighted)
            .font(.system(size: 13, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var highlighted: AttributedString {
        var result = AttributedString(code)
        let base = UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1)
        result.foregroundColor = base

        // Apply passes in priority order (later passes can override)
        for pass in passes(for: language) {
            apply(pass: pass, to: &result)
        }
        return result
    }

    // MARK: - Pass application
    // Uses NSRegularExpression on the plain string, then maps ranges to AttributedString.

    private func apply(pass: SyntaxPass, to text: inout AttributedString) {
        guard let regex = try? NSRegularExpression(
            pattern: pass.pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return }

        let plain = text.description
        let nsRange = NSRange(plain.startIndex..., in: plain)
        let matches = regex.matches(in: plain, range: nsRange)

        for match in matches.reversed() {
            // Use capture group 1 if present, otherwise the full match
            let targetRange = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                ? match.range(at: 1)
                : match.range

            guard let swiftRange = Range(targetRange, in: plain),
                  let attrRange = Range(swiftRange, in: text) else { continue }
            text[attrRange].foregroundColor = pass.color
        }
    }

    // MARK: - Language pass sets

    private func passes(for language: String) -> [SyntaxPass] {
        let lang = language.lowercased()
        if lang.contains("swift")      { return swiftPasses }
        if lang.contains("python")     { return pythonPasses }
        if lang.contains("kotlin")     { return kotlinPasses }
        if lang.contains("java") && !lang.contains("script") { return javaPasses }
        if lang.contains("javascript") || lang.contains("typescript") || lang.contains("tsx") || lang.contains("jsx") { return jsPasses }
        if lang.contains("rust")       { return rustPasses }
        if lang.contains("go")         { return goPasses }
        if lang.contains("c++") || lang.contains("cpp") || lang.contains("c") { return cppPasses }
        if lang.contains("ruby")       { return rubyPasses }
        if lang.contains("shell") || lang.contains("bash") || lang.contains("sh") { return shellPasses }
        if lang.contains("sql")        { return sqlPasses }
        return genericPasses
    }
}

// MARK: - SyntaxPass definition

struct SyntaxPass {
    let pattern: String
    let color: UIColor
}

// MARK: - Color palette

private extension UIColor {
    // Dracula-inspired palette
    static let synComment  = UIColor(red: 0.38, green: 0.45, blue: 0.55, alpha: 1) // grey
    static let synString   = UIColor(red: 0.95, green: 0.80, blue: 0.50, alpha: 1) // amber
    static let synKeyword  = UIColor(red: 1.00, green: 0.40, blue: 0.60, alpha: 1) // pink
    static let synType     = UIColor(red: 0.60, green: 0.85, blue: 1.00, alpha: 1) // light blue
    static let synFunc     = UIColor(red: 0.55, green: 1.00, blue: 0.75, alpha: 1) // mint
    static let synNumber   = UIColor(red: 0.75, green: 0.60, blue: 1.00, alpha: 1) // lavender
    static let synBuiltin  = UIColor(red: 1.00, green: 0.65, blue: 0.25, alpha: 1) // orange
    static let synOperator = UIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1) // light grey
}

// MARK: - Swift

private let swiftPasses: [SyntaxPass] = [
    // Block comments
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    // Line comments
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    // Multiline strings
    SyntaxPass(pattern: #""""[\s\S]*?""""#,                              color: .synString),
    // Single-line strings (handles escaped quotes)
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    // Keywords
    SyntaxPass(pattern: #"\b(let|var|func|class|struct|enum|protocol|extension|import|typealias|where|for|in|while|if|else|guard|return|switch|case|default|break|continue|throw|throws|rethrows|try|catch|defer|do|repeat|as|is|nil|true|false|self|Self|super|inout|mutating|nonmutating|static|final|override|open|public|internal|private|fileprivate|async|await|actor|some|any|consuming|borrowing|isolated|nonisolated|package)\b"#, color: .synKeyword),
    // Attributes
    SyntaxPass(pattern: #"@\w+"#,                                        color: .synBuiltin),
    // Function/method names
    SyntaxPass(pattern: #"\bfunc\s+(\w+)"#,                             color: .synFunc),
    // Type names (PascalCase)
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    // Numbers
    SyntaxPass(pattern: #"\b(0x[0-9a-fA-F]+|0b[01]+|0o[0-7]+|\d+\.?\d*([eE][+-]?\d+)?)\b"#, color: .synNumber),
]

// MARK: - Python

private let pythonPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"#[^\n]*"#,                                     color: .synComment),
    SyntaxPass(pattern: #"(?:\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?''')"#,    color: .synComment),  // docstrings
    SyntaxPass(pattern: #"(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#,   color: .synString),
    SyntaxPass(pattern: #"\b(def|class|if|elif|else|for|while|import|from|return|pass|break|continue|lambda|try|except|finally|with|as|and|or|not|in|is|True|False|None|async|await|yield|global|nonlocal|del|raise|assert)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"@\w+"#,                                        color: .synBuiltin),
    SyntaxPass(pattern: #"\bdef\s+(\w+)"#,                              color: .synFunc),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b(print|len|range|type|isinstance|enumerate|zip|map|filter|sorted|list|dict|set|tuple|int|float|str|bool|bytes|open|super|property|classmethod|staticmethod|abs|max|min|sum|any|all|hasattr|getattr|setattr|vars)\b"#, color: .synBuiltin),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?\b"#,              color: .synNumber),
]

// MARK: - JavaScript / TypeScript

private let jsPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #"`(?:[^`\\]|\\.)*`"#,                          color: .synString),  // template literals
    SyntaxPass(pattern: #"(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#,   color: .synString),
    SyntaxPass(pattern: #"\b(const|let|var|function|return|if|else|for|while|class|interface|type|import|export|from|async|await|new|typeof|instanceof|null|undefined|true|false|this|super|throw|try|catch|finally|switch|case|break|continue|default|delete|in|of|void|yield|extends|implements|enum|namespace|readonly|declare|abstract|static|override|private|protected|public)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\b(function|=>)\s*\n?"#,                      color: .synKeyword),
    SyntaxPass(pattern: #"\bfunction\s+(\w+)"#,                         color: .synFunc),
    SyntaxPass(pattern: #"(?<=\s|^|;|\()(\w+)\s*\("#,                  color: .synFunc),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b(console|Math|Object|Array|String|Number|Boolean|Promise|JSON|Error|Date|RegExp|Symbol|Map|Set|WeakMap|WeakSet|Proxy|Reflect)\b"#, color: .synBuiltin),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?\b"#,              color: .synNumber),
]

// MARK: - Kotlin

private let kotlinPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #""""[\s\S]*?""""#,                              color: .synString),
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    SyntaxPass(pattern: #"\b(val|var|fun|class|object|interface|enum|sealed|data|when|if|else|for|while|return|import|package|is|as|in|null|true|false|this|super|override|abstract|open|final|private|protected|public|internal|companion|suspend|coroutineScope|launch|async|await|by|constructor|init|get|set|it|typealias|inline|reified|crossinline|noinline|tailrec|operator|infix|external|annotation)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\bfun\s+(\w+)"#,                              color: .synFunc),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?(L|f|F)?\b"#,     color: .synNumber),
]

// MARK: - Java

private let javaPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    SyntaxPass(pattern: #"\b(public|private|protected|static|final|abstract|synchronized|volatile|transient|native|class|interface|enum|extends|implements|new|return|if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|throws|import|package|instanceof|this|super|null|true|false|void|int|long|double|float|boolean|char|byte|short)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"@\w+"#,                                        color: .synBuiltin),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?(L|f|F|d|D)?\b"#, color: .synNumber),
]

// MARK: - Rust

private let rustPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    SyntaxPass(pattern: #"'[^']'"#,                                      color: .synString),  // char
    SyntaxPass(pattern: #"\b(fn|let|mut|const|static|struct|enum|impl|trait|type|use|mod|pub|crate|super|self|return|if|else|for|in|while|loop|match|break|continue|where|async|await|move|ref|box|dyn|unsafe|extern|as)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"#\[[\s\S]*?\]"#,                              color: .synBuiltin),  // attributes
    SyntaxPass(pattern: #"\bfn\s+(\w+)"#,                               color: .synFunc),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?(_[a-z0-9]+)?\b"#, color: .synNumber),
]

// MARK: - Go

private let goPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #"`[\s\S]*?`"#,                                  color: .synString),  // raw strings
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    SyntaxPass(pattern: #"\b(func|var|const|type|struct|interface|map|chan|go|select|defer|package|import|return|if|else|for|range|switch|case|default|break|continue|goto|fallthrough|nil|true|false|make|new|len|cap|append|copy|delete|close|panic|recover|print|println|error)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\bfunc\s+(?:\(\w+\s+\*?\w+\)\s+)?(\w+)"#,   color: .synFunc),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?\b"#,              color: .synNumber),
]

// MARK: - C / C++

private let cppPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"//[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #"#[^\n]*"#,                                     color: .synBuiltin),  // preprocessor
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    SyntaxPass(pattern: #"'(?:[^'\\]|\\.)*'"#,                          color: .synString),
    SyntaxPass(pattern: #"\b(auto|break|case|char|class|const|continue|default|delete|do|double|else|enum|explicit|extern|float|for|friend|goto|if|inline|int|long|mutable|namespace|new|noexcept|nullptr|operator|override|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while|bool|true|false|constexpr|decltype|nullptr|static_assert|thread_local)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9_]*)\b"#,                  color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*([eE][+-]?\d+)?(u|l|ul|ll|ull|f|F)?\b"#, color: .synNumber),
]

// MARK: - Ruby

private let rubyPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"#[^\n]*"#,                                     color: .synComment),
    SyntaxPass(pattern: #"(?:"(?:[^"\\]|\\.)*"|'[^']*')"#,             color: .synString),
    SyntaxPass(pattern: #":[a-zA-Z_]\w*"#,                              color: .synBuiltin),  // symbols
    SyntaxPass(pattern: #"\b(def|class|module|end|if|elsif|else|unless|while|until|for|in|do|begin|rescue|ensure|raise|return|yield|super|self|nil|true|false|and|or|not|require|include|extend|attr_accessor|attr_reader|attr_writer|puts|print|p|lambda|proc|new|initialize|protected|private|public)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\bdef\s+(\w+)"#,                              color: .synFunc),
    SyntaxPass(pattern: #"\b([A-Z][A-Za-z0-9]*)\b"#,                   color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*\b"#,                             color: .synNumber),
]

// MARK: - Shell / Bash

private let shellPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"#[^\n]*"#,                                     color: .synComment),
    SyntaxPass(pattern: #"(?:"(?:[^"\\]|\\.)*"|'[^']*')"#,             color: .synString),
    SyntaxPass(pattern: #"\$\{?[\w@#?$!*-]+\}?"#,                       color: .synBuiltin),  // variables
    SyntaxPass(pattern: #"\b(if|then|else|elif|fi|for|in|do|done|while|until|case|esac|function|return|exit|export|local|readonly|declare|source|echo|printf|read|test|set|unset|shift|break|continue|trap|exec|eval)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\b\d+\b"#,                                    color: .synNumber),
]

// MARK: - SQL

private let sqlPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"--[^\n]*"#,                                    color: .synComment),
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #"'(?:[^'\\]|\\.)*'"#,                          color: .synString),
    SyntaxPass(pattern: #"\b(SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|FULL|ON|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|INDEX|VIEW|DROP|ALTER|ADD|COLUMN|PRIMARY|KEY|FOREIGN|REFERENCES|UNIQUE|NOT|NULL|DEFAULT|CHECK|CONSTRAINT|AS|AND|OR|IN|IS|LIKE|BETWEEN|EXISTS|UNION|ALL|DISTINCT|CASE|WHEN|THEN|ELSE|END|BEGIN|COMMIT|ROLLBACK|TRANSACTION|GRANT|REVOKE)\b"#, color: .synKeyword),
    SyntaxPass(pattern: #"\b([A-Z][A-Z0-9_]+)\b"#,                     color: .synType),
    SyntaxPass(pattern: #"\b\d+\.?\d*\b"#,                             color: .synNumber),
]

// MARK: - Generic fallback

private let genericPasses: [SyntaxPass] = [
    SyntaxPass(pattern: #"(?://|#)[^\n]*"#,                             color: .synComment),
    SyntaxPass(pattern: #"/\*[\s\S]*?\*/"#,                              color: .synComment),
    SyntaxPass(pattern: #""(?:[^"\\]|\\.)*""#,                          color: .synString),
    SyntaxPass(pattern: #"'(?:[^'\\]|\\.)*'"#,                          color: .synString),
    SyntaxPass(pattern: #"\b\d+\.?\d*\b"#,                             color: .synNumber),
]
