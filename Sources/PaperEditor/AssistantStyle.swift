import SwiftUI

/// Everything the chat is drawn with, in one place, so its pieces agree: five colors, two
/// corner radii, three text sizes, one icon column and one kind of small button.
enum AssistantStyle {
    // MARK: Colors
    // Plain colors over the panel rather than the system's layered styles, so a box looks
    // the same wherever it is drawn.

    /// What is read: messages and answers.
    static let text = Color.primary.opacity(0.92)
    /// What steps back: what the assistant did, captions, icons at rest.
    static let dim = Color.primary.opacity(0.55)
    /// What is not available.
    static let faint = Color.primary.opacity(0.3)
    /// Behind a box: a message, the composer, code.
    static let fill = Color.primary.opacity(0.06)
    /// Behind something small that sits on a box or is under the pointer: a chip, a button.
    static let raised = Color.primary.opacity(0.09)
    static let line = Color.primary.opacity(0.12)

    // MARK: Sizes

    /// A box's corners, and those of something small.
    static let radius: CGFloat = 10
    static let smallRadius: CGFloat = 6
    /// From the panel's edge to a box, and from a box's edge to what is in it.
    static let margin: CGFloat = 14
    static let inset: CGFloat = 10
    /// The column icons sit in, and the gap before the text beside them.
    static let iconColumn: CGFloat = 16
    static let iconGap: CGFloat = 8
    /// Between two blocks of the transcript, and between lines inside one.
    static let blockSpacing: CGFloat = 16
    static let lineSpacing: CGFloat = 6
    /// The height of a control in the composer, and of a chip.
    static let control: CGFloat = 24
    static let chipHeight: CGFloat = 22

    // MARK: Type

    /// Messages, answers, what is typed.
    static let body = Font.body
    /// Rows about what happened, chips, menus.
    static let small = Font.callout
    /// A caption beside something small.
    static let tiny = Font.caption
    static let rowIcon = Font.system(size: 11, weight: .medium)
}

extension View {
    /// A filled box with the chat's corners and inset; `outlined` adds its hairline.
    func assistantBox(outlined: Bool = false, highlighted: Bool = false) -> some View {
        padding(AssistantStyle.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantStyle.fill, in: .rect(cornerRadius: AssistantStyle.radius))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: AssistantStyle.radius).strokeBorder(.tint, lineWidth: 2)
                } else if outlined {
                    RoundedRectangle(cornerRadius: AssistantStyle.radius).strokeBorder(AssistantStyle.line)
                }
            }
    }
}

/// One line about something that happened: an icon in the icon column, then what it says.
struct AssistantRow<Content: View>: View {
    var symbol: String
    var color: Color = AssistantStyle.dim
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AssistantStyle.iconGap) {
            Image(systemName: symbol)
                .font(AssistantStyle.rowIcon)
                .frame(width: AssistantStyle.iconColumn)
            content
        }
        .font(AssistantStyle.small)
        .foregroundStyle(color)
    }
}

/// The chat's small button: an icon that lights up under the pointer.
struct AssistantIconButtonStyle: ButtonStyle {
    var size: CGFloat = AssistantStyle.control
    var iconSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, size: size, iconSize: iconSize)
    }

    private struct Face: View {
        let configuration: Configuration
        let size: CGFloat
        let iconSize: CGFloat
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(!isEnabled ? AssistantStyle.faint : isHovered ? AssistantStyle.text : AssistantStyle.dim)
                .frame(width: size, height: size)
                .background(isHovered && isEnabled ? AssistantStyle.raised : .clear, in: .rect(cornerRadius: AssistantStyle.smallRadius))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

/// A box that is a button: a starter request, a suggestion.
struct AssistantBoxButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(AssistantStyle.small)
                .foregroundStyle(AssistantStyle.text)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, AssistantStyle.inset)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? AssistantStyle.raised : AssistantStyle.fill, in: .rect(cornerRadius: AssistantStyle.radius))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}
