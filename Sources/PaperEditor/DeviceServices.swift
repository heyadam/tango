import AVFoundation
import AppKit
import CoreLocation
import PaperEngine
import PaperModel

/// Gives a running prototype this Mac's hardware: camera, microphone, location, haptics
/// and sound. Each service starts only when the prototype has a patch or layer that needs
/// it, which is also when the system asks the person for permission.
final class DeviceServices: NSObject {
    private weak var runtime: Runtime?
    /// Called after a value arrives, so the Viewer draws a frame.
    var onChange: (() -> Void)?
    private var active: Set<DeviceCapability> = []

    init(runtime: Runtime) {
        self.runtime = runtime
        super.init()
    }

    /// Starts what the prototype needs and stops what it no longer does.
    func sync(_ wanted: Set<DeviceCapability>) {
        guard wanted != active else { return }
        for capability in DeviceCapability.allCases {
            let needed = wanted.contains(capability)
            guard needed != active.contains(capability) else { continue }
            switch capability {
            case .camera: needed ? startCamera() : stopCamera()
            case .microphone: needed ? startMicrophone() : stopMicrophone()
            case .location: needed ? startLocation() : stopLocation()
            case .clock: needed ? startClock() : stopClock()
            case .appearance: if needed { reportAppearance() }
            }
        }
        active = wanted
    }

    func stop() { sync([]) }

    func perform(_ effect: DeviceEffect) {
        switch effect {
        case let .haptic(style):
            let pattern: NSHapticFeedbackManager.FeedbackPattern =
                style == "Alignment" ? .alignment : style == "Level Change" ? .levelChange : .generic
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        case let .sound(name, volume):
            play(name, volume: volume)
        case .capturePhoto:
            capturePhoto()
        }
    }

    private func set(_ key: String, _ value: Value) {
        runtime?.setDevice(key, value)
        onChange?()
    }

    // MARK: Sound

    private var sounds: [String: NSSound] = [:]

    private func play(_ name: String, volume: Double) {
        let sound: NSSound?
        if let cached = sounds[name] {
            sound = cached
        } else if name == "Shutter" {
            let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
            sound = NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
        } else {
            sound = NSSound(named: name)
        }
        guard let sound else { return }
        sounds[name] = sound
        sound.stop()
        sound.volume = Float(volume)
        sound.play()
    }

    // MARK: Appearance and clock

    private var clock: Timer?

    private func reportAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        set("device.name", .text(Host.current().localizedName ?? "Mac"))
        set("device.dark", .bool(dark))
        set("device.scale", .number(Double(NSScreen.main?.backingScaleFactor ?? 2)))
    }

    private func startClock() {
        reportTime()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func reportTime() {
        let now = Date()
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        set("clock.hours", .number(Double(parts.hour ?? 0)))
        set("clock.minutes", .number(Double(parts.minute ?? 0)))
        set("clock.seconds", .number(Double(parts.second ?? 0)))
        set("clock.time", .text(now.formatted(date: .omitted, time: .shortened)))
        set("clock.date", .text(now.formatted(date: .abbreviated, time: .omitted)))
    }

    // MARK: Microphone

    private var audio: AVAudioEngine?

    private func startMicrophone() {
        set("microphone.available", .bool(false))
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in
                guard let self, granted, self.active.contains(.microphone), self.audio == nil else { return }
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0 else { return }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                    var sum: Float = 0
                    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                    let rms = (sum / Float(buffer.frameLength)).squareRoot()
                    // Map roughly -50 dB…0 dB onto 0…1.
                    let decibels = 20 * log10(max(rms, 0.000_01))
                    let level = Double(min(max((decibels + 50) / 50, 0), 1))
                    Task { @MainActor [weak self] in self?.set("microphone.level", .number(level)) }
                }
                do {
                    try engine.start()
                    self.audio = engine
                    self.set("microphone.available", .bool(true))
                } catch {
                    input.removeTap(onBus: 0)
                }
            }
        }
    }

    private func stopMicrophone() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        set("microphone.level", .number(0))
        set("microphone.available", .bool(false))
    }

    // MARK: Location

    private var locator: CLLocationManager?

    private func startLocation() {
        set("location.available", .bool(false))
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        locator = manager
    }

    private func stopLocation() {
        locator?.stopUpdatingLocation()
        locator = nil
    }

    // MARK: Camera

    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var photos: [String: CGImage] = [:]
    private var photoCount = 0
    /// The live picture, for Camera views. nil until the camera is running.
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// A photo taken by the Camera patch, by the name its Photo output carries.
    func photo(named name: String) -> CGImage? { photos[name] }

    private func startCamera() {
        set("camera.available", .bool(false))
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor [weak self] in
                guard let self, granted, self.active.contains(.camera), self.session == nil,
                      let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera)
                else { return }
                let session = AVCaptureSession()
                session.sessionPreset = .photo
                let output = AVCapturePhotoOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else { return }
                session.addInput(input)
                session.addOutput(output)
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                self.session = session
                self.photoOutput = output
                self.previewLayer = preview
                // Starting the session blocks, so it happens off the main thread.
                let starter = SessionBox(session)
                DispatchQueue.global(qos: .userInitiated).async { starter.session.startRunning() }
                self.set("camera.available", .bool(true))
            }
        }
    }

    private func stopCamera() {
        if let session {
            let stopper = SessionBox(session)
            DispatchQueue.global(qos: .utility).async { stopper.session.stopRunning() }
        }
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        photoOutput = nil
        session = nil
        set("camera.available", .bool(false))
    }

    private func capturePhoto() {
        guard let photoOutput, session?.isRunning == true else { return }
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    fileprivate func received(photo data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        photoCount += 1
        let name = "capture:\(photoCount)"
        // Only the latest few are kept.
        if photos.count > 4 { photos.removeAll() }
        photos[name] = image
        runtime?.setDevice("camera.photo", .text(name))
        runtime?.deviceEvent("camera.captured")
        onChange?()
    }
}

/// Carries a capture session to the background queue that starts or stops it.
private final class SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

extension DeviceServices: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        Task { @MainActor [weak self] in
            self?.set("location.latitude", .number(latitude))
            self?.set("location.longitude", .number(longitude))
            self?.set("location.available", .bool(true))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.set("location.available", .bool(false)) }
    }
}

extension DeviceServices: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor [weak self] in self?.received(photo: data) }
    }
}
