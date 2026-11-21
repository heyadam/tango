import SwiftUI

/// An answer from the assistant, which writes Markdown: paragraphs, headings, lists and
/// code, with emphasis, inline code and links inside them.
struct AssistantMarkdown: View {
    let text: String

    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        /// `marker` is "•" or a number with its dot; `indent` counts levels in.
        case item(marker: String, indent: Int, text: String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AssistantStyle.iconGap) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(text):
                    Text(Self.inline(text))
                case let .heading(text):
                    Text(Self.inline(text)).font(.body.weight(.semibold)).padding(.top, 4)
                case let .item(marker, indent, text):
                    HStack(alignment: .firstTextBaseline, spacing: AssistantStyle.lineSpacing) {
                        Text(marker).foregroundStyle(AssistantStyle.dim).monospacedDigit()
                        Text(Self.inline(text))
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                    // Items of one list sit closer than paragraphs do.
                    .padding(.top, -4)
                case let .code(code):
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(AssistantStyle.small.monospaced())
                            .padding(AssistantStyle.inset)
                    }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AssistantStyle.fill, in: .rect(cornerRadius: AssistantStyle.radius))
                }
            }
        }
        .font(AssistantStyle.body)
        .lineSpacing(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        // Inline code in the size the code blocks use, not the larger system default.
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = AssistantStyle.small.monospaced()
        }
        return styled
    }

    /// Splits Markdown into the blocks drawn above. Text still arriving may end inside a
    /// code fence; what follows the fence is then code so far.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    endParagraph()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                endParagraph()
            } else if let heading = trimmed.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                endParagraph()
                blocks.append(.heading(String(heading.1)))
            } else if let item = line.firstMatch(of: /^(\s*)([-*•]|\d+[.)])\s+(.+)$/) {
                endParagraph()
                let marker = item.2.first?.isNumber == true ? String(item.2.dropLast()) + "." : "•"
                blocks.append(.item(marker: marker, indent: min(item.1.count / 2, 4), text: String(item.3)))
            } else {
                paragraph.append(trimmed)
            }
        }
        endParagraph()
        if let code, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }
}
