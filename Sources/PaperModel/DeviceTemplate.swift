/// A screen size to design for. Choosing one sets the screen's size; the Viewer then takes
/// the same proportions. The document stores only the size, so a size that matches no
/// template is simply Custom.
public struct DeviceTemplate: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// In points.
    public let size: Size2

    public init(id: String, name: String, size: Size2) {
        self.id = id
        self.name = name
        self.size = size
    }

    public static let iPhone18Pro = DeviceTemplate(
        id: "iphone-18-pro", name: "iPhone 18 Pro", size: Size2(width: 402, height: 874)
    )
    public static let desktop = DeviceTemplate(
        id: "desktop", name: "Desktop", size: Size2(width: 1400, height: 900)
    )

    public static let all: [DeviceTemplate] = [.iPhone18Pro, .desktop]

    /// The template with exactly this size, if any.
    public static func matching(_ size: Size2) -> DeviceTemplate? {
        all.first { $0.size == size }
    }

    /// "402 × 874".
    public var dimensions: String {
        "\(size.width.whole) × \(size.height.whole)"
    }
}

extension Document {
    /// A new, empty document whose screen is sized for a device: what File > New makes.
    public static func blank(for device: DeviceTemplate = .iPhone18Pro) -> Document {
        Document(screen: Layer(name: "Screen", kind: .screen, properties: [.size: .size(device.size)]))
    }
}
