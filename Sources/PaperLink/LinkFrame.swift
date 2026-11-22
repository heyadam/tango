import CryptoKit
import Foundation

/// One message on the wire: a length, the message as JSON, a length, the payload.
///
///     "TNGO"  u32 header length  header JSON  u32 payload length  payload
///
/// Both lengths are big-endian. Parsing is a pure function over the bytes received so
/// far, so everything that can be wrong with a frame is tested without a socket.
public struct LinkFrame: Equatable, Sendable {
    public var message: LinkMessage
    public var payload: Data

    public init(_ message: LinkMessage, payload: Data = Data()) {
        self.message = message
        self.payload = payload
    }

    static let magic = Data("TNGO".utf8)
    public static let largestHeader = 1 << 20
    public static let largestPayload = 256 << 20

    public func encoded() throws -> Data {
        let header = try JSONEncoder().encode(message)
        guard header.count <= Self.largestHeader, payload.count <= Self.largestPayload else { throw LinkError.tooLarge }
        var data = Self.magic
        data.append(Self.length(header.count))
        data.append(header)
        data.append(Self.length(payload.count))
        data.append(payload)
        return data
    }

    public enum Parsed: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        /// Not a frame, or one too large to take: the connection should be dropped.
        case invalid
        /// A frame, and how many bytes of the buffer it took.
        case frame(LinkFrame, length: Int)
    }

    /// Nothing is copied until the whole frame is here, so a large file arriving in many
    /// pieces costs a look at two lengths each time, not a copy of what has arrived.
    public static func parse(_ buffer: Data) -> Parsed {
        let count = buffer.count
        // Not yet a whole start: it is a frame so far only if it begins as one does.
        guard buffer.prefix(4).elementsEqual(magic.prefix(min(count, 4))) else { return .invalid }
        guard count >= 8 else { return .incomplete }
        let headerLength = number(buffer, at: 4)
        guard headerLength > 0, headerLength <= largestHeader else { return .invalid }
        let payloadAt = 8 + headerLength + 4
        guard count >= payloadAt else { return .incomplete }
        let payloadLength = number(buffer, at: 8 + headerLength)
        guard payloadLength <= largestPayload else { return .invalid }
        guard count >= payloadAt + payloadLength else { return .incomplete }
        let start = buffer.startIndex
        guard let message = try? JSONDecoder().decode(
            LinkMessage.self, from: buffer.subdata(in: (start + 8)..<(start + 8 + headerLength))
        ) else { return .invalid }
        let payload = buffer.subdata(in: (start + payloadAt)..<(start + payloadAt + payloadLength))
        return .frame(LinkFrame(message, payload: payload), length: payloadAt + payloadLength)
    }

    private static func length(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
    }

    /// A length, `offset` bytes into `data`, wherever `data` starts in its storage.
    private static func number(_ data: Data, at offset: Int) -> Int {
        let start = data.startIndex + offset
        return data[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
    }
}

enum SHA256Digest {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
