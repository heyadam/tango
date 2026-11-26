import Foundation
import PaperModel

/// Icons, fonts and photos from outside the app: what each is, and what is shipped or
/// fetched, is said where each is drawn (`IconSet`, `FontBook`, `Unsplash`).
extension StandardPatches {
    static let media: [PatchDefinition] = [icon, font, unsplashPhoto]

    /// Names an icon of any set for a Symbol view's Symbol input.
    static let icon = PatchDefinition(
        kind: PatchKind.icon, name: "Icon", category: .media,
        summary: "Names an icon from SF Symbols, Lucide or Material Symbols, for a Symbol view to show.",
        inputs: [
            PortSpec("set", "Set", .text, .text(IconSet.lucide.displayName), options: IconSet.allCases.map(\.displayName)),
            PortSpec("name", "Name", .text, .text("heart")),
            PortSpec("filled", "Filled", .bool, .bool(false)),
        ],
        outputs: [PortSpec("symbol", "Symbol", .text, .text("lucide:heart")), PortSpec("known", "Known", .bool, .bool(true))]
    ) { ctx in
        let icon = iconName(set: ctx.text(0), name: ctx.text(1), filled: ctx.bool(2))
        ctx.outputs[0] = .text(icon?.value ?? "")
        ctx.outputs[1] = .bool(icon?.isKnown ?? false)
    }

    /// The icon the Icon patch's inputs name. A Name that is already a whole `symbol`
    /// value (`material:home`) is taken as it is.
    static func iconName(set: String, name: String, filled: Bool) -> IconName? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.contains(":"), var whole = IconName(name) {
            if filled, whole.set.isMaterial || whole.set == .sf { whole.filled = true }
            return whole
        }
        let chosen = IconSet.named(set) ?? .lucide
        // People write Lucide's names with spaces and capitals, and Material's with hyphens.
        var cleaned = name
        switch chosen {
        case .lucide: cleaned = name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        case .material, .materialRounded, .materialSharp:
            cleaned = name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        case .sf: break
        }
        if chosen.isMaterial, cleaned.hasSuffix(".fill") { return IconName(set: chosen, name: String(cleaned.dropLast(5)), filled: true) }
        return IconName(set: chosen, name: cleaned, filled: filled && chosen != .lucide)
    }

    /// Names a typeface for a text's Font input.
    static let font = PatchDefinition(
        kind: PatchKind.font, name: "Font", category: .media,
        summary: "Names a typeface for a Text or Text Field: the system's, an Apple family every device has, or any Google Fonts family.",
        inputs: [PortSpec("family", "Family", .text, .text("Inter"))],
        outputs: [PortSpec("font", "Font", .text, .text("Inter")), PortSpec("source", "Source", .text, .text("Google Fonts"))]
    ) { ctx in
        let asked = ctx.text(0).trimmingCharacters(in: .whitespaces)
        if FontBook.isSystemDesign(asked) {
            ctx.outputs[0] = .text(asked == "System" ? "" : asked)
            ctx.outputs[1] = .text("System")
        } else if let system = FontBook.systemFamilies.first(where: { $0.caseInsensitiveCompare(asked) == .orderedSame }) {
            ctx.outputs[0] = .text(system)
            ctx.outputs[1] = .text("System")
        } else if let family = GoogleFonts.family(asked) {
            ctx.outputs[0] = .text(family.name)
            ctx.outputs[1] = .text("Google Fonts")
        } else {
            // Installed on this Mac, perhaps, but not on every device: shown as asked.
            ctx.outputs[0] = .text(asked)
            ctx.outputs[1] = .text("Unknown")
        }
    }

    /// A photo from Unsplash: searched for, or chosen at random.
    static let unsplashPhoto = PatchDefinition(
        kind: PatchKind.unsplashPhoto, name: "Unsplash Photo", category: .media,
        summary: "Finds photos on Unsplash and gives one as an Image, with its photographer's name to credit. Needs an Unsplash access key in Settings.",
        inputs: [
            PortSpec("query", "Search", .text, .text("")),
            PortSpec("orientation", "Orientation", .text, .text("Any"), options: Unsplash.orientations),
            PortSpec("index", "Index", .number, .number(0)),
            PortSpec("next", "Next", .pulse),
            PortSpec("size", "Size", .text, .text("Regular"), options: Unsplash.sizes),
        ],
        outputs: [
            PortSpec("image", "Image", .text),
            PortSpec("photographer", "Photographer", .text),
            PortSpec("profile", "Profile", .text),
            PortSpec("description", "Description", .text),
            PortSpec("color", "Color", .color, .color(ColorValue(white: 0.85))),
            PortSpec("count", "Count", .number),
            PortSpec("loading", "Loading", .bool),
            PortSpec("error", "Error", .text),
        ]
    ) { ctx in Unsplash.evaluate(&ctx) }
}

extension IconName {
    /// The icon the Icon patch's inputs name: a Set, a Name (a whole `symbol` value is
    /// taken as it is) and whether it is Filled.
    public static func forPatch(set: String, name: String, filled: Bool) -> IconName? {
        StandardPatches.iconName(set: set, name: name, filled: filled)
    }
}

extension PatchKind {
    public static let icon = "icon"
    public static let font = "font"
    public static let unsplashPhoto = "unsplashPhoto"
}

/// Unsplash's photos (unsplash.com/developers). Nothing of them is shipped or kept: the
/// API's terms ask that photos be shown from Unsplash's own servers (hotlinked), that the
/// photographer be credited with a link back, and that a photo's download be reported when
/// it is used. So the patch fetches every time the prototype runs, the host keeps what it
/// fetched only while the prototype runs, and the patch reports each photo it shows once.
/// Requests carry the service `unsplash`, for which the host adds the person's access key.
public enum Unsplash {
    public static let service = "unsplash"
    public static let apiHost = "api.unsplash.com"
    public static let orientations = ["Any", "Landscape", "Portrait", "Squarish"]
    public static let sizes = ["Small", "Regular", "Full"]
    /// How many photos one search brings back; Index and Next choose among them.
    public static let perPage = 30

    struct Photo: Sendable, Equatable {
        var id: String
        var urls: [String: String]
        var photographer: String
        var profile: String
        var description: String
        var color: ColorValue
        var downloadLocation: String
    }

    struct State: Sendable {
        var asked: String?
        var photos: [Photo] = []
        var searchToken: Int?
        var error = ""
        var nextCount = 0
        var token = 0
        /// The picture fetched for each photo and size, and the requests on their way.
        var pictures: [String: String] = [:]
        var pictureTokens: [Int: String] = [:]
        var reported: Set<String> = []
    }

    /// The address a search asks; none of its words reach anywhere but Unsplash's API.
    static func searchURL(query: String, orientation: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = [URLQueryItem(name: "content_filter", value: "high")]
        if orientation != "Any", orientations.contains(orientation) {
            items.append(URLQueryItem(name: "orientation", value: orientation.lowercased()))
        }
        if query.isEmpty {
            components.path = "/photos/random"
            items.append(URLQueryItem(name: "count", value: String(perPage)))
        } else {
            components.path = "/search/photos"
            items.append(URLQueryItem(name: "query", value: String(query.prefix(200))))
            items.append(URLQueryItem(name: "per_page", value: String(perPage)))
        }
        components.queryItems = items
        return components.url?.absoluteString ?? ""
    }

    /// The photos an answer lists: a search's `results`, or the array a random pick gives.
    static func photos(in body: Data) -> [Photo] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        let list = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, let urls = item["urls"] as? [String: String] else { return nil }
            let user = item["user"] as? [String: Any] ?? [:]
            let links = user["links"] as? [String: Any] ?? [:]
            let photoLinks = item["links"] as? [String: Any] ?? [:]
            let profile = (links["html"] as? String).map { $0 + "?utm_source=tango&utm_medium=referral" } ?? ""
            return Photo(
                id: id, urls: urls, photographer: user["name"] as? String ?? "", profile: profile,
                description: (item["description"] as? String) ?? (item["alt_description"] as? String) ?? "",
                color: ColorValue(hex: item["color"] as? String ?? "") ?? ColorValue(white: 0.85),
                downloadLocation: photoLinks["download_location"] as? String ?? ""
            )
        }
    }

    /// An address on Unsplash's servers for pictures, or nil: a listing cannot send the
    /// patch anywhere else.
    static func pictureURL(_ photo: Photo, size: String) -> String? {
        let key = switch size {
        case "Small": "small"
        case "Full": "full"
        default: "regular"
        }
        guard let address = photo.urls[key] ?? photo.urls["regular"], let url = URL(string: address),
              url.scheme == "https", url.host == "images.unsplash.com"
        else { return nil }
        return address
    }

    static func evaluate(_ ctx: inout EvalContext) {
        var state = ctx.state as? State ?? State()
        let query = ctx.text(0), orientation = ctx.text(1)
        let asked = query + "\n" + orientation

        for reply in ctx.replies {
            if reply.token == state.searchToken {
                state.searchToken = nil
                if let error = reply.response.error {
                    state.error = error
                } else if reply.response.status != 200 {
                    state.error = errorMessage(reply.response)
                } else {
                    state.photos = photos(in: reply.response.body)
                    state.error = state.photos.isEmpty ? "No photos found." : ""
                    state.pictures = [:]
                    state.pictureTokens = [:]
                }
            } else if let key = state.pictureTokens.removeValue(forKey: reply.token) {
                if reply.response.error == nil, reply.response.status == 200 {
                    state.pictures[key] = NetworkRequest.pictureName(for: reply.id)
                } else {
                    state.error = reply.response.error ?? "The photo could not be loaded."
                }
            }
        }

        if state.asked != asked {
            state.asked = asked
            state.token += 1
            state.searchToken = state.token
            state.error = ""
            ctx.requests.append(ScriptRequest(
                token: state.token, url: searchURL(query: query, orientation: orientation), method: "GET",
                headers: ["Accept-Version": "v1"], body: "", timeout: 20, service: service
            ))
        }
        if ctx.pulse(3) { state.nextCount += 1 }

        var loading = state.searchToken != nil
        if !state.photos.isEmpty {
            let count = state.photos.count
            let index = ((ctx.number(2).whole + state.nextCount) % count + count) % count
            let photo = state.photos[index]
            let size = sizes.contains(ctx.text(4)) ? ctx.text(4) : "Regular"
            let key = photo.id + " " + size
            if let picture = state.pictures[key] {
                ctx.outputs[0] = .text(picture)
            } else {
                loading = true
                if !state.pictureTokens.values.contains(key), let address = pictureURL(photo, size: size) {
                    state.token += 1
                    state.pictureTokens[state.token] = key
                    ctx.requests.append(ScriptRequest(token: state.token, url: address, method: "GET", headers: [:], body: "", timeout: 30))
                }
            }
            // Unsplash asks to hear when a photo is used; once per photo, its answer unread.
            if !state.reported.contains(photo.id), !photo.downloadLocation.isEmpty,
               URL(string: photo.downloadLocation)?.host == apiHost {
                state.reported.insert(photo.id)
                state.token += 1
                ctx.requests.append(ScriptRequest(
                    token: state.token, url: photo.downloadLocation, method: "GET",
                    headers: ["Accept-Version": "v1"], body: "", timeout: 20, service: service
                ))
            }
            ctx.outputs[1] = .text(photo.photographer)
            ctx.outputs[2] = .text(photo.profile)
            ctx.outputs[3] = .text(photo.description)
            ctx.outputs[4] = .color(photo.color)
        }
        ctx.outputs[5] = .number(Double(state.photos.count))
        ctx.outputs[6] = .bool(loading)
        ctx.outputs[7] = .text(state.error)
        ctx.state = state
    }

    /// A request for Unsplash's API with the access key added, or nil when it is for
    /// anywhere else: the key goes to Unsplash's API and nowhere else.
    public static func signed(_ request: NetworkRequest, key: String) -> NetworkRequest? {
        guard let url = URL(string: request.url), url.scheme == "https", url.host == apiHost, url.port == nil,
              request.method == "GET", !key.contains(where: \.isNewline)
        else { return nil }
        var signed = request
        signed.headers["Authorization"] = "Client-ID " + key
        return signed
    }

    static func errorMessage(_ response: NetworkResponse) -> String {
        switch response.status {
        case 401: return "Unsplash did not accept the access key. Check it in Settings."
        case 403: return "Unsplash refused: the key's hourly limit may be used up."
        default:
            if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let errors = object["errors"] as? [String], let first = errors.first { return first }
            return "Unsplash answered \(response.status)."
        }
    }
}
