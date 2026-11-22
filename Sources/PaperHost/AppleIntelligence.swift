import AVFoundation
import CoreGraphics
import Foundation
import FoundationModels
import NaturalLanguage
import PaperEngine
import PaperModel
import Speech
import Translation

/// Answers the AI requests that go to Apple's models (`AIProvider.apple`), on the device
/// the prototype runs on: Foundation Models for text and objects, the system's voices for
/// speech, SpeechAnalyzer for transcription and Translation for translating. Nothing needs
/// a key and nothing leaves the device, so unlike the cloud providers nobody is asked first.
///
/// One per running prototype, like `AIService` on the Mac, which hands it these requests;
/// the iPhone player's `PrototypeHost` uses it alone. Recording stays with the host: it
/// passes a finished recording to `transcribe(_:for:)`.
public final class AppleIntelligence {
    /// Hands an update to the runtime, then draws a frame.
    public var deliver: (UUID, AIUpdate) -> Void = { _, _ in }
    /// A picture the prototype can show, by name: what Image inputs name.
    public var picture: (String) -> CGImage? = { _ in nil }
    /// Set while the prototype is out of sight: speech that arrives then is not played.
    public var hidden = false

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var voices: [UUID: Voice] = [:]

    public init() {}

    /// Starts a request sent to an Apple model, or cancels one.
    public func handle(_ request: AIRequest) {
        if request.phase == .cancel { return cancel(request.id) }
        guard request.phase == .send else { return }
        switch request.task {
        case .text: respond(request)
        case .object: makeObject(request)
        case .translation: translate(request)
        case .speech: speak(request)
        case .image: deliver(request.id, .failed(Self.noImages))
        case .transcription: break
        }
    }

    public func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        if let voice = voices.removeValue(forKey: id) { voice.synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Stops everything: the prototype restarted or closed.
    public func stopAll() {
        for id in Set(tasks.keys).union(voices.keys) { cancel(id) }
    }

    /// Stops speaking, and says so as if it had ended: the prototype was hidden.
    public func quiet() {
        hidden = true
        for id in Array(voices.keys) {
            voices.removeValue(forKey: id)?.synthesizer.stopSpeaking(at: .immediate)
            deliver(id, .playing(false))
        }
    }

    public var isBusy: Bool { !tasks.isEmpty || !voices.isEmpty }

    // MARK: Whether it can run

    /// Why Apple's language model cannot answer here, in words; nil when it can.
    nonisolated public static var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case let .unavailable(reason): problem(reason)
        }
    }

    /// What Settings says about the model on this device.
    public static var status: (available: Bool, detail: String) {
        if let unavailable { return (false, unavailable) }
        return (true, SystemLanguageModel.default.variant.displayName)
    }

    nonisolated static func problem(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device cannot run Apple Intelligence, so apple-on-device has nothing to answer with."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use apple-on-device."
        case .modelNotReady: "Apple's on-device model is still downloading. Try again in a few minutes."
        @unknown default: "Apple's on-device model is not available on this device."
        }
    }

    static let noImages = "Apple's models do not make pictures from code. Use an OpenAI image model."

    /// An error from a model, in words a person can act on.
    static func words(for error: any Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return "The conversation is too long for the on-device model. Reset it, or turn Remember off."
            case .guardrailViolation: return "Apple's model declined: the prompt or the answer tripped its safety guardrails."
            case .refusal: return "Apple's model declined to answer that."
            case .unsupportedLanguageOrLocale: return "Apple's on-device model does not speak this language yet."
            case .unsupportedCapability, .unsupportedTranscriptContent: return "Apple's on-device model cannot do this, such as read this picture."
            case .unsupportedGenerationGuide: return "Apple's on-device model cannot make one of these fields."
            case .timeout: return "Apple's on-device model took too long to answer."
            case .rateLimited: return "Apple's on-device model is busy. Try again in a moment."
            @unknown default: break
            }
        }
        if let error = error as? LanguageModelSession.Error, error == .concurrentRequests {
            return "Apple's model is still answering the last request."
        }
        return error.localizedDescription
    }

    // MARK: Text

    private func respond(_ request: AIRequest) {
        let id = request.id
        if let unavailable = Self.unavailable { return deliver(id, .failed(unavailable)) }
        let image = request.picture.isEmpty ? nil : picture(request.picture)
        if !request.picture.isEmpty, image == nil, request.prompt.isEmpty {
            return deliver(id, .failed("The picture in Image could not be found."))
        }
        let session = LanguageModelSession(transcript: Self.transcript(instructions: request.instructions, history: request.conversation))
        let deliver = self.deliver
        tasks[id] = Task { [weak self] in
            do {
                let stream = Self.stream(session, prompt: request.prompt, image: image)
                var text = ""
                for try await snapshot in stream {
                    if Task.isCancelled { return }
                    text = snapshot.content
                    deliver(id, .partial(text))
                }
                if Task.isCancelled { return }
                deliver(id, .finished(text: text, picture: ""))
            } catch {
                if !Task.isCancelled { deliver(id, .failed(Self.words(for: error))) }
            }
            self?.tasks[id] = nil
        }
    }

    private static func stream(_ session: LanguageModelSession, prompt: String, image: CGImage?) -> LanguageModelSession.ResponseStream<String> {
        let words = prompt.isEmpty ? "Describe this picture." : prompt
        guard let image else { return session.streamResponse(to: Prompt(words)) }
        return session.streamResponse { Attachment(image); words }
    }

    /// The conversation so far as a transcript to start a session from. Pictures shown in
    /// earlier turns are not shown again: only the newest prompt carries one.
    static func transcript(instructions: String, history: [AITurn]) -> Transcript {
        func text(_ words: String) -> [Transcript.Segment] { [.text(.init(content: words))] }
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty {
            entries.append(.instructions(.init(segments: text(instructions), toolDefinitions: [])))
        }
        for turn in history {
            switch turn.role {
            case .user: entries.append(.prompt(.init(segments: text(turn.text.isEmpty ? "(a picture)" : turn.text))))
            case .assistant: entries.append(.response(.init(assetIDs: [], segments: text(turn.text))))
            }
        }
        return Transcript(entries: entries)
    }

    // MARK: Objects

    private func makeObject(_ request: AIRequest) {
        let id = request.id
        if let unavailable = Self.unavailable { return deliver(id, .failed(unavailable)) }
        let fields = AIField.parse(request.fields)
        guard !fields.isEmpty else {
            return deliver(id, .failed("List what to make in Fields, one a line, such as title: text."))
        }
        let schema: GenerationSchema
        do {
            schema = try Self.schema(for: fields)
        } catch {
            return deliver(id, .failed("Fields could not be made into a schema: \(error.localizedDescription)"))
        }
        let image = request.picture.isEmpty ? nil : picture(request.picture)
        let session = LanguageModelSession(transcript: Self.transcript(instructions: request.instructions, history: []))
        let words = request.prompt.isEmpty ? "Fill these in from the picture." : request.prompt
        let deliver = self.deliver
        tasks[id] = Task { [weak self] in
            do {
                let stream = if let image {
                    session.streamResponse(schema: schema) { Attachment(image); words }
                } else {
                    session.streamResponse(to: Prompt(words), schema: schema)
                }
                var json = "{}"
                for try await snapshot in stream {
                    if Task.isCancelled { return }
                    json = snapshot.rawContent.jsonString
                    deliver(id, .partial(json))
                }
                if Task.isCancelled { return }
                deliver(id, .finished(text: json, picture: ""))
            } catch {
                if !Task.isCancelled { deliver(id, .failed(Self.words(for: error))) }
            }
            self?.tasks[id] = nil
        }
    }

    /// The schema that holds the model to `fields`.
    /// The schemas inside are named by place, not by field, so no field name can collide
    /// with another schema's.
    static func schema(for fields: [AIField]) throws -> GenerationSchema {
        func schema(_ kind: AIField.Kind, named name: String) -> DynamicGenerationSchema {
            switch kind {
            case .text: DynamicGenerationSchema(type: String.self)
            case .number: DynamicGenerationSchema(type: Double.self)
            case .whole: DynamicGenerationSchema(type: Int.self)
            case .bool: DynamicGenerationSchema(type: Bool.self)
            case let .choice(choices): DynamicGenerationSchema(name: name, anyOf: choices)
            case let .list(element, count):
                DynamicGenerationSchema(arrayOf: schema(element, named: name + ".item"), minimumElements: count, maximumElements: count)
            }
        }
        let root = DynamicGenerationSchema(name: "tango.object", properties: fields.enumerated().map { index, field in
            DynamicGenerationSchema.Property(
                name: field.name, description: field.about.isEmpty ? nil : field.about,
                schema: schema(field.kind, named: "tango.field\(index)")
            )
        })
        return try GenerationSchema(root: root, dependencies: [])
    }

    // MARK: Translation

    private func translate(_ request: AIRequest) {
        let id = request.id
        guard !request.target.isEmpty else { return deliver(id, .failed("Say which language to translate into in To.")) }
        let deliver = self.deliver
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            let target = Locale.Language(identifier: request.target)
            var sourceCode = request.source
            if sourceCode.isEmpty {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(request.prompt)
                guard let found = recognizer.dominantLanguage else {
                    return deliver(id, .failed("Could not tell what language Text is in. Choose it in From."))
                }
                sourceCode = found.rawValue
            }
            let source = Locale.Language(identifier: sourceCode)
            if source.minimalIdentifier == target.minimalIdentifier {
                return deliver(id, .finished(text: request.prompt, picture: ""))
            }
            let status = await LanguageAvailability().status(from: source, to: target)
            // Replaced or stopped while it looked: nothing to say.
            if Task.isCancelled { return }
            switch status {
            case .installed:
                break
            case .supported:
                return deliver(id, .failed("Add \(Self.name(of: source)) and \(Self.name(of: target)) in System Settings > General > Language & Region > Translation Languages to translate between them on this device."))
            case .unsupported:
                return deliver(id, .failed("Apple cannot translate from \(Self.name(of: source)) to \(Self.name(of: target))."))
            @unknown default:
                break
            }
            do {
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(request.prompt)
                if Task.isCancelled { return }
                deliver(id, .finished(text: response.targetText, picture: ""))
            } catch {
                if !Task.isCancelled { deliver(id, .failed(error.localizedDescription)) }
            }
        }
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    // MARK: Speech

    /// One utterance and the synthesizer saying it.
    private final class Voice: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        let synthesizer = AVSpeechSynthesizer()
        let done: () -> Void
        init(_ done: @escaping () -> Void) {
            self.done = done
            super.init()
            synthesizer.delegate = self
        }
        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.done() }
        }
    }

    private func speak(_ request: AIRequest) {
        let id = request.id
        // Fetched at once: there is nothing to wait for.
        deliver(id, .finished(text: "", picture: ""))
        guard !hidden else { return deliver(id, .playing(false)) }
        #if os(iOS)
        // The player's session would follow the ring switch; speech is what was asked for.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: request.prompt)
        utterance.voice = Self.voice(named: request.voice)
        let voice = Voice { [weak self] in
            guard let self, self.voices.removeValue(forKey: id) != nil else { return }
            self.deliver(id, .playing(false))
        }
        voices[id] = voice
        voice.synthesizer.speak(utterance)
        deliver(id, .playing(true))
    }

    /// A system voice by name (Samantha) or identifier, else the device's own for its language.
    static func voice(named name: String) -> AVSpeechSynthesisVoice? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: name) { return voice }
            let all = AVSpeechSynthesisVoice.speechVoices()
            let named = all.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let best = named.max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return best }
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    // MARK: Transcription

    /// Turns a finished recording into words on the device, then reports `.finished` (or
    /// `.failed`) for `id` and calls `done` so the host can delete the file.
    public func transcribe(_ file: URL, for id: UUID, done: @escaping () -> Void = {}) {
        let deliver = self.deliver
        tasks[id] = Task { [weak self] in
            defer {
                done()
                self?.tasks[id] = nil
            }
            do {
                let heard = try await Self.words(in: file)
                if Task.isCancelled { return }
                deliver(id, .finished(text: heard, picture: ""))
            } catch {
                if !Task.isCancelled { deliver(id, .failed("Could not transcribe on this device: \(error.localizedDescription)")) }
            }
        }
    }

    /// What is said in an audio file, by SpeechAnalyzer in this device's language,
    /// fetching its model the first time.
    static func words(in file: URL) async throws -> String {
        var found = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if found == nil { found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = found else { throw CocoaError(.featureUnsupported) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)
        let collected = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        if let end = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
