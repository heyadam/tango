import AppKit
import SwiftUI

/// Finds the parts of Metal shader code that are colored: comments, numbers, keywords,
/// types and the functions Metal provides. It reads the text only; it does not parse it.
enum ShaderHighlighter {
    enum Kind: Equatable {
        case comment, number, keyword, type, function, directive

        var color: NSColor {
            switch self {
            case .comment: .secondaryLabelColor
            case .number: .systemOrange
            case .keyword: .systemPink
            case .type: .systemTeal
            case .function: .systemPurple
            case .directive: .systemBrown
            }
        }
    }

    struct Token: Equatable {
        let range: NSRange
        let kind: Kind
    }

    static let keywords: Set<String> = [
        "struct", "return", "if", "else", "for", "while", "do", "break", "continue", "switch", "case", "default",
        "const", "constexpr", "static", "inline", "true", "false", "using", "namespace", "typedef",
        "vertex", "fragment", "kernel", "constant", "discard_fragment",
    ]

    static let types: Set<String> = {
        var names: Set<String> = ["void", "bool", "int", "uint", "short", "ushort", "char", "uchar", "float", "half", "size_t",
                                  "sampler", "texture2d", "Frame", "Inputs"]
        for base in ["float", "half", "int", "uint", "bool", "short", "ushort"] {
            for count in 2...4 { names.insert("\(base)\(count)") }
        }
        for size in 2...4 {
            names.insert("float\(size)x\(size)")
            names.insert("half\(size)x\(size)")
        }
        return names
    }()

    static let functions: Set<String> = [
        "content", "shader",
        "abs", "acos", "asin", "atan", "atan2", "ceil", "clamp", "cos", "cosh", "cross", "degrees", "determinant",
        "distance", "dot", "exp", "exp2", "floor", "fma", "fmax", "fmin", "fmod", "fract", "inverse", "length",
        "log", "log2", "log10", "max", "min", "mix", "modf", "normalize", "pow", "radians", "reflect", "refract",
        "round", "rsqrt", "saturate", "sign", "sin", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh",
        "transpose", "trunc", "dfdx", "dfdy", "fwidth", "select", "any", "all",
    ]

    private static let pattern = try! NSRegularExpression(pattern: [
        #"(//[^\n]*|/\*[\s\S]*?(?:\*/|$))"#,                               // 1 comment
        #"(^[ \t]*#[^\n]*)"#,                                              // 2 directive
        #"((?<![A-Za-z_.])(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[fFuU]?)"#,   // 3 number
        #"([A-Za-z_][A-Za-z0-9_]*)"#,                                      // 4 word
    ].joined(separator: "|"), options: [.anchorsMatchLines])

    static func tokens(in text: String) -> [Token] {
        let string = text as NSString
        var result: [Token] = []
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                result.append(Token(range: match.range(at: 1), kind: .comment))
            } else if match.range(at: 2).location != NSNotFound {
                result.append(Token(range: match.range(at: 2), kind: .directive))
            } else if match.range(at: 3).location != NSNotFound {
                result.append(Token(range: match.range(at: 3), kind: .number))
            } else {
                let range = match.range(at: 4)
                let word = string.substring(with: range)
                // A member, as in `frame.size` or `color.rgb`, is left plain.
                if range.location > 0, string.character(at: range.location - 1) == 46 { return }
                if keywords.contains(word) {
                    result.append(Token(range: range, kind: .keyword))
                } else if types.contains(word) {
                    result.append(Token(range: range, kind: .type))
                } else if functions.contains(word) {
                    result.append(Token(range: range, kind: .function))
                }
            }
        }
        return result
    }

    /// Where line `number` (from 1) is in `text`, or nil when there is no such line.
    static func range(ofLine number: Int, in text: String) -> NSRange? {
        guard number >= 1 else { return nil }
        let string = text as NSString
        var location = 0
        for _ in 1..<number {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            guard NSMaxRange(line) > location, NSMaxRange(line) < string.length else { return nil }
            location = NSMaxRange(line)
        }
        return string.lineRange(for: NSRange(location: location, length: 0))
    }

    /// The line a compiler message such as "Line 12: …" names.
    static func line(in problem: String?) -> Int? {
        guard let problem, problem.hasPrefix("Line ") else { return nil }
        return Int(problem.dropFirst(5).prefix { $0.isNumber })
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// Colors all of `storage`, and marks the line a problem is on.
    static func apply(to storage: NSTextStorage, errorLine: Int?) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        for token in tokens(in: text) {
            storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
        }
        if let errorLine, let range = range(ofLine: errorLine, in: text) {
            storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.2), range: range)
        }
        storage.endEditing()
    }
}

/// A code editor: a standard text view with a fixed-width font, the colors of
/// `ShaderHighlighter`, and none of the corrections meant for prose.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    /// The line to mark as having a problem, from 1.
    var errorLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.font = ShaderHighlighter.font
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.typingAttributes = [.font: ShaderHighlighter.font, .foregroundColor: NSColor.labelColor]
        view.string = text
        context.coordinator.highlight(view, errorLine: errorLine)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            // Changed from outside: keep the insertion point where it was, as far as it goes.
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.highlight(view, errorLine: errorLine)
        } else if context.coordinator.shownErrorLine != errorLine {
            context.coordinator.highlight(view, errorLine: errorLine)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        var shownErrorLine: Int?

        init(_ parent: CodeTextView) { self.parent = parent }

        func highlight(_ view: NSTextView, errorLine: Int?) {
            guard let storage = view.textStorage else { return }
            shownErrorLine = errorLine
            ShaderHighlighter.apply(to: storage, errorLine: errorLine)
            view.typingAttributes = [.font: ShaderHighlighter.font, .foregroundColor: NSColor.labelColor]
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            highlight(view, errorLine: shownErrorLine)
            parent.text = view.string
        }

        /// Tab indents by four spaces, and Return keeps the indentation of the line above.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                view.insertText("    ", replacementRange: view.selectedRange())
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let string = view.string as NSString
                let line = string.lineRange(for: NSRange(location: view.selectedRange().location, length: 0))
                let before = string.substring(with: NSRange(location: line.location, length: view.selectedRange().location - line.location))
                let indent = String(before.prefix { $0 == " " || $0 == "\t" })
                view.insertText("\n" + indent, replacementRange: view.selectedRange())
                return true
            }
            return false
        }
    }
}
