import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Vision

enum NativeCameraWireFormat {
    static let magic = Data([0x54, 0x4f, 0x43, 0x4d]) // "TOCM"
    static let version: UInt8 = 1
    static let headerBytes = 16
    static let pixelFormat = "NV12"

    enum MessageKind: UInt8 {
        case status = 1
        case frame = 2
    }

    static func message(kind: MessageKind, sequence: UInt32, payload: Data) -> Data {
        var result = Data(capacity: headerBytes + payload.count)
        result.append(magic)
        result.append(version)
        result.append(kind.rawValue)
        result.append(contentsOf: [0, 0])
        append(UInt32(payload.count), to: &result)
        append(sequence, to: &result)
        result.append(payload)
        return result
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

/// The frame geometry the bridge captures on the Mac and publishes to the
/// guest. NV12 at 1280×720, 30 fps by default; a smaller format such as
/// 640x480@30 costs a quarter of the per-frame copy and virtio traffic, which
/// matters for video calls on a busy VM. The guest learns the geometry from
/// the bridge's first status message and reconfigures its loopback camera.
struct NativeCameraFrameFormat: Equatable {
    static let environmentKey = "OMARCHY_QEMU_GPU_CAMERA_FORMAT"
    static let userDefaultsKey = "cameraFormat"
    static let `default` = NativeCameraFrameFormat(width: 1280, height: 720, framesPerSecond: 30)
    static let widthRange = 160...3840
    static let heightRange = 120...2160
    static let frameRateRange = 1...120

    let width: Int
    let height: Int
    let framesPerSecond: Int

    var frameBytes: Int { width * height * 3 / 2 }

    var label: String { "\(width)x\(height)@\(framesPerSecond)" }

    /// The session preset matching the geometry, so FaceTime HD cameras do
    /// not deliver 1080p output while their active input format is smaller.
    var captureSessionPreset: AVCaptureSession.Preset {
        switch (width, height) {
        case (320, 240): return .qvga320x240
        case (640, 480): return .vga640x480
        case (960, 540): return .qHD960x540
        case (1280, 720): return .hd1280x720
        case (1920, 1080): return .hd1920x1080
        case (3840, 2160): return .hd4K3840x2160
        // Other sizes rely on the output's pixel-buffer width and height,
        // which scale whatever the preset delivers to the wire geometry.
        default: return .high
        }
    }

    func videoSettings() -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    }

    /// Parses `WIDTHxHEIGHT` or `WIDTHxHEIGHT@FPS`. Both dimensions must be
    /// even, as NV12 stores chroma at half resolution.
    static func parse(_ text: String) -> NativeCameraFrameFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let rateParts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard rateParts.count <= 2 else { return nil }
        let sizeParts = rateParts[0].split(separator: "x", omittingEmptySubsequences: false)
        guard sizeParts.count == 2,
              let width = Int(sizeParts[0]),
              let height = Int(sizeParts[1]) else { return nil }
        var framesPerSecond = `default`.framesPerSecond
        if rateParts.count == 2 {
            guard let rate = Int(rateParts[1]) else { return nil }
            framesPerSecond = rate
        }
        guard widthRange.contains(width), heightRange.contains(height),
              width % 2 == 0, height % 2 == 0,
              frameRateRange.contains(framesPerSecond) else { return nil }
        return NativeCameraFrameFormat(width: width, height: height, framesPerSecond: framesPerSecond)
    }

    /// The configured format: `OMARCHY_QEMU_GPU_CAMERA_FORMAT` in the
    /// environment, then the `cameraFormat` user default
    /// (`defaults write dev.tryomarchy.native cameraFormat 640x480@30`),
    /// then the 720p default. An unparsable value is reported and ignored.
    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedValue: String? = UserDefaults.standard.string(forKey: userDefaultsKey),
        warn: (String) -> Void = { fputs("[camera-bridge] \($0)\n", stderr) }
    ) -> NativeCameraFrameFormat {
        guard let requested = environment[environmentKey] ?? storedValue else { return `default` }
        guard let format = parse(requested) else {
            warn("ignoring camera format \"\(requested)\"; expected WIDTHxHEIGHT[@FPS] such as 640x480@30")
            return `default`
        }
        return format
    }
}

/// What replaces the scene behind the person in the frames sent to the guest.
///
/// Video-call apps inside the VM cannot blur or replace the background
/// themselves: their segmentation models need a GPU the VirGL guest does not
/// offer, so they stutter on the CPU. The bridge does the same work on the
/// Mac instead, with Vision's person segmentation on the Neural Engine and a
/// Core Image composite on the GPU, before the frame crosses into the guest.
enum NativeCameraBackground: Equatable {
    case none
    case blur(radius: Double)
    case image(URL)

    static let environmentKey = "OMARCHY_QEMU_GPU_CAMERA_BACKGROUND"
    static let userDefaultsKey = "cameraBackground"
    static let defaultBlurRadius = 12.0
    static let blurRadiusRange = 1.0...80.0

    var label: String {
        switch self {
        case .none: "none"
        case .blur(let radius): "blur:\(Int(radius.rounded()))"
        case .image(let url): "image:\(url.path)"
        }
    }

    /// Accepts `none`, `blur`, `blur:RADIUS` (in pixels of a 640-wide frame),
    /// or the path of an image file, optionally prefixed with `image:`.
    static func parse(_ text: String) -> NativeCameraBackground? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        switch lowered {
        case "none", "off": return .none
        case "blur": return .blur(radius: defaultBlurRadius)
        default: break
        }
        if lowered.hasPrefix("blur:") || lowered.hasPrefix("blur=") {
            guard let radius = Double(lowered.dropFirst(5)), blurRadiusRange.contains(radius) else { return nil }
            return .blur(radius: radius)
        }
        var path = trimmed
        if lowered.hasPrefix("image:") { path = String(trimmed.dropFirst(6)) }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return .image(URL(fileURLWithPath: path))
    }

    /// `OMARCHY_QEMU_GPU_CAMERA_BACKGROUND` in the environment, then the
    /// `cameraBackground` user default
    /// (`defaults write dev.tryomarchy.native cameraBackground blur`), then none.
    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedValue: String? = UserDefaults.standard.string(forKey: userDefaultsKey),
        warn: (String) -> Void = { fputs("[camera-bridge] \($0)\n", stderr) }
    ) -> NativeCameraBackground {
        guard let requested = environment[environmentKey] ?? storedValue else { return .none }
        guard let background = parse(requested) else {
            warn("ignoring camera background \"\(requested)\"; expected none, blur, blur:RADIUS or an image path")
            return .none
        }
        return background
    }
}

/// Applies a `NativeCameraBackground` to NV12 camera frames of one geometry.
/// Used on the frame callback queue only.
final class NativeCameraBackgroundEffect {
    private let format: NativeCameraFrameFormat
    private let background: NativeCameraBackground
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "dev.tryomarchy.camera-background"])
    private let request = VNGeneratePersonSegmentationRequest()
    private let blend = CIFilter.blendWithMask()
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let output: CVPixelBuffer
    private let backdrop: CIImage?
    private let blurSigma: Double

    init(background: NativeCameraBackground, format: NativeCameraFrameFormat) throws {
        self.format = format
        self.background = background
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            format.width,
            format.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw HelperError.io("cannot allocate a camera frame for the background effect")
        }
        output = buffer

        let frame = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        switch background {
        case .none:
            throw HelperError.io("no camera background effect requested")
        case .blur(let radius):
            // The radius is specified for a 640-wide frame; scale it so the
            // effect looks the same at every wire geometry.
            blurSigma = radius * Double(format.width) / 640
            backdrop = nil
        case .image(let url):
            blurSigma = 0
            guard let image = CIImage(contentsOf: url) else {
                throw HelperError.io("cannot read the camera background image at \(url.path)")
            }
            // Scale to fill the frame, centre, and crop; render once so the
            // per-frame composite does not decode the file again.
            let scale = max(frame.width / image.extent.width, frame.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centred = scaled.transformed(by: CGAffineTransform(
                translationX: (frame.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (frame.height - scaled.extent.height) / 2 - scaled.extent.minY
            ))
            guard let rendered = context.createCGImage(centred, from: frame) else {
                throw HelperError.io("cannot prepare the camera background image")
            }
            backdrop = CIImage(cgImage: rendered)
        }
    }

    func apply(to source: CVPixelBuffer) throws -> CVPixelBuffer {
        let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:])
        try handler.perform([request])
        guard let maskBuffer = request.results?.first?.pixelBuffer else {
            throw HelperError.io("person segmentation produced no mask")
        }
        let image = CIImage(cvPixelBuffer: source)
        // Soften the mask edge slightly before scaling it to the frame.
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: mask.extent)
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: image.extent.width / mask.extent.width,
            y: image.extent.height / mask.extent.height
        ))
        let behind: CIImage
        if let backdrop {
            behind = backdrop
        } else {
            behind = image.clampedToExtent().applyingGaussianBlur(sigma: blurSigma).cropped(to: image.extent)
        }
        blend.inputImage = image
        blend.backgroundImage = behind
        blend.maskImage = mask
        guard let composite = blend.outputImage else {
            throw HelperError.io("cannot composite the camera background")
        }
        CVBufferPropagateAttachments(source, output)
        context.render(composite, to: output, bounds: image.extent, colorSpace: colorSpace)
        return output
    }
}

/// Requests the guest bridge writes as JSON lines on the virtio channel.
enum NativeCameraGuestRequest: Equatable {
    /// Start streaming. The guest names the geometry its loopback device is
    /// currently programmed with, so frames always fit even when the guest
    /// has not yet adopted the host's preferred format.
    case start(NativeCameraFrameFormat)
    case stop
    /// Re-send the current status; the guest asks on start-up because a
    /// status written before its port was open is dropped by virtio-serial.
    case status

    static func parse(_ object: [String: Any], preferred: NativeCameraFrameFormat) -> NativeCameraGuestRequest? {
        guard let type = object["type"] as? String else { return nil }
        let keys = object.keys.sorted()
        switch type {
        case "start":
            if keys == ["type"] { return .start(preferred) }
            guard keys == ["height", "type", "width"],
                  let width = object["width"] as? Int,
                  let height = object["height"] as? Int,
                  let format = NativeCameraFrameFormat.parse(
                      "\(width)x\(height)@\(preferred.framesPerSecond)"
                  ) else { return nil }
            return .start(format)
        case "stop":
            return keys == ["type"] ? .stop : nil
        case "status":
            return keys == ["type"] ? .status : nil
        default:
            return nil
        }
    }
}

enum NativeCameraSessionLifecycle {
    static let failureNotifications = [
        AVCaptureSession.runtimeErrorNotification,
        AVCaptureSession.didStopRunningNotification,
    ]

    static func shouldTerminateBridge(streaming: Bool, stopped: Bool) -> Bool {
        streaming && !stopped
    }
}

final class NativeCameraBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let descriptor: Int32
    private let sessionQueue = DispatchQueue(label: "dev.tryomarchy.native.camera-session")
    private let videoQueue = DispatchQueue(
        label: "dev.tryomarchy.native.camera-frames",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var session: AVCaptureSession?
    private var sessionObservers: [NSObjectProtocol] = []
    private var streaming = false
    private var stopped = false
    private var cameraName = "Mac Camera"
    private let background: NativeCameraBackground
    /// Guarded by `stateLock`; created for the active geometry when streaming
    /// starts and dropped after its first failure so frames keep flowing.
    private var backgroundEffect: NativeCameraBackgroundEffect?
    private var backgroundEffectFailed = false
    private var sequence: UInt32 = 0
    /// The geometry the Mac prefers (announced while idle).
    private let format: NativeCameraFrameFormat
    /// The geometry the current capture session produces; guarded by
    /// `stateLock` because the frame callback reads it on the video queue.
    private var activeFormatStorage: NativeCameraFrameFormat
    private var activeFormat: NativeCameraFrameFormat {
        get { stateLock.lock(); defer { stateLock.unlock() }; return activeFormatStorage }
        set { stateLock.lock(); activeFormatStorage = newValue; stateLock.unlock() }
    }

    init(
        targetPID: pid_t,
        socketPath: String,
        format: NativeCameraFrameFormat = .configured(),
        background: NativeCameraBackground = .configured()
    ) throws {
        self.format = format
        self.background = background
        activeFormatStorage = format
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native camera bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "camera bridge")
        super.init()
    }

    deinit {
        stop()
    }

    func run() throws {
        try sendStatus(idleStatus())
        prewarmCaptureSession()
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    try handle(line)
                    line.removeAll(keepingCapacity: true)
                } else if byte != 0x0D {
                    guard line.count < 4096 else {
                        throw HelperError.io("guest camera request exceeds 4 KiB")
                    }
                    line.append(byte)
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest camera channel")
            }
        }
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        streaming = false
        stateLock.unlock()

        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            removeSessionObservers()
            self.session?.stopRunning()
            self.session = nil
        }
    }

    private func handle(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = NativeCameraGuestRequest.parse(object, preferred: format) else {
            throw HelperError.io("guest sent an invalid camera request")
        }
        switch request {
        case .start(let requested):
            try startCapture(at: requested)
        case .stop:
            stopCapture()
        case .status:
            try sendStatus(currentStatus())
        }
    }

    private func startCapture(at requested: NativeCameraFrameFormat) throws {
        stateLock.lock()
        let alreadyStreaming = streaming
        let isStopped = stopped
        stateLock.unlock()
        guard !alreadyStreaming, !isStopped else { return }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            try sendStatus(["reason": "permission", "status": "unavailable"])
            return
        }

        try sessionQueue.sync {
            // A pre-warmed session at another geometry is discarded; frames
            // must match the loopback device the guest is streaming into.
            if session != nil, activeFormat != requested {
                removeSessionObservers()
                session = nil
            }
            activeFormat = requested
            let captureSession: AVCaptureSession
            let cameraName: String
            if let existing = session,
               let input = existing.inputs.first as? AVCaptureDeviceInput {
                captureSession = existing
                cameraName = input.device.localizedName
            } else {
                let configured = try makeCaptureSession()
                captureSession = configured.session
                cameraName = configured.cameraName
                session = captureSession
                observeSessionFailures(captureSession)
            }
            captureSession.startRunning()
            guard captureSession.isRunning else {
                throw HelperError.io("the Mac camera capture session did not start")
            }
            let effect = makeBackgroundEffect(for: requested)
            stateLock.lock()
            streaming = true
            self.cameraName = cameraName
            backgroundEffect = effect
            stateLock.unlock()
            try sendStatus(currentStatus())
        }
    }

    private func makeBackgroundEffect(for format: NativeCameraFrameFormat) -> NativeCameraBackgroundEffect? {
        stateLock.lock()
        let failed = backgroundEffectFailed
        stateLock.unlock()
        guard background != .none, !failed else { return nil }
        do {
            return try NativeCameraBackgroundEffect(background: background, format: format)
        } catch {
            fputs("[camera-bridge] camera background disabled: \(error.localizedDescription)\n", stderr)
            stateLock.lock()
            backgroundEffectFailed = true
            stateLock.unlock()
            return nil
        }
    }

    /// Streaming status describes the frames actually being sent; idle status
    /// describes the geometry the Mac would prefer the guest to adopt.
    private func currentStatus() -> [String: Any] {
        stateLock.lock()
        let isStreaming = streaming
        let name = cameraName
        let active = activeFormatStorage
        stateLock.unlock()
        guard isStreaming else { return idleStatus() }
        return [
            "background": background.label,
            "fps": active.framesPerSecond,
            "height": active.height,
            "name": name,
            "pixelFormat": NativeCameraWireFormat.pixelFormat,
            "status": "streaming",
            "width": active.width,
        ]
    }

    private func stopCapture() {
        stateLock.lock()
        let wasStreaming = streaming
        streaming = false
        stateLock.unlock()
        guard wasStreaming else { return }
        sessionQueue.sync {
            session?.stopRunning()
        }
        try? sendStatus(idleStatus())
    }

    /// Build the capture session before the guest asks for frames. Device
    /// discovery and format negotiation are most of the cold-start delay the
    /// first video call sees; the camera itself, and its indicator, stay off
    /// until `startCapture()` runs the session. Failures here are not fatal:
    /// `startCapture()` retries the configuration and reports its own error.
    private func prewarmCaptureSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isStopped = self.stopped
            self.stateLock.unlock()
            guard !isStopped, self.session == nil else { return }
            do {
                let configured = try self.makeCaptureSession()
                self.session = configured.session
                self.observeSessionFailures(configured.session)
            } catch {
                fputs("[camera-bridge] camera pre-warm skipped: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    /// The idle status carries the frame geometry so the guest can size its
    /// loopback camera before the first frame arrives.
    private func idleStatus() -> [String: Any] {
        [
            "background": background.label,
            "fps": format.framesPerSecond,
            "height": format.height,
            "pixelFormat": NativeCameraWireFormat.pixelFormat,
            "status": "idle",
            "width": format.width,
        ]
    }

    private func makeCaptureSession() throws -> (session: AVCaptureSession, cameraName: String) {
        let format = activeFormat
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        // A preferred camera can be named by unique ID or by a case-insensitive
        // name fragment, through the OMARCHY_QEMU_GPU_CAMERA environment
        // variable or the `cameraDevice` user default
        // (`defaults write dev.tryomarchy.native cameraDevice "HDM Webcam"`).
        // Otherwise the built-in FaceTime camera keeps its historical priority.
        let preference = ProcessInfo.processInfo.environment["OMARCHY_QEMU_GPU_CAMERA"]
            ?? UserDefaults.standard.string(forKey: "cameraDevice")
        let preferred = preference.flatMap { wanted -> AVCaptureDevice? in
            let trimmed = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return discovery.devices.first { $0.uniqueID == trimmed }
                ?? discovery.devices.first { $0.localizedName.localizedCaseInsensitiveContains(trimmed) }
        }
        guard let device = preferred ?? discovery.devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("FaceTime")
        }) ?? AVCaptureDevice.default(for: .video) else {
            throw HelperError.io("this Mac has no available camera")
        }

        // Pick the configured-size format whose frame-rate range comes closest to the
        // nominal rate. USB cameras report fixed ranges a hair under the
        // nominal value (30000030 ticks per second reads as 29.99997 fps), so
        // an exact `>= 30` test rejected every external camera; allow a small
        // tolerance and prefer a range that truly contains the nominal rate.
        let nominalRate = Double(format.framesPerSecond)
        let rateTolerance = 0.5
        var selection: (format: AVCaptureDevice.Format, range: AVFrameRateRange)?
        for candidate in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
            guard Int(dimensions.width) == format.width,
                  Int(dimensions.height) == format.height else { continue }
            for range in candidate.videoSupportedFrameRateRanges {
                guard range.minFrameRate <= nominalRate + rateTolerance,
                      range.maxFrameRate >= nominalRate - rateTolerance else { continue }
                let distance = abs(range.maxFrameRate - nominalRate)
                if let current = selection, abs(current.range.maxFrameRate - nominalRate) <= distance {
                    continue
                }
                selection = (candidate, range)
            }
        }
        guard let selection else {
            throw HelperError.io(
                "the Mac camera \(device.localizedName) does not support \(format.label)"
            )
        }
        let targetFormat = selection.format
        // A fixed-rate range accepts only its own frame duration, so use the
        // device's value unless the range genuinely contains the nominal rate.
        let containsNominal = selection.range.minFrameRate <= nominalRate
            && selection.range.maxFrameRate >= nominalRate
        let frameDuration = containsNominal
            ? CMTime(value: 1, timescale: CMTimeScale(format.framesPerSecond))
            : selection.range.minFrameDuration

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = format.videoSettings()
        output.setSampleBufferDelegate(self, queue: videoQueue)

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        // The default `.high` preset produces 1080p output on FaceTime HD
        // cameras even when their active input format is smaller.
        captureSession.sessionPreset = format.captureSessionPreset
        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            throw HelperError.io("the Mac camera cannot be attached to the native bridge")
        }
        captureSession.addInput(input)
        captureSession.addOutput(output)

        // Configure the device while it belongs to the session's configuration
        // transaction, as required by AVFoundation's active-format contract.
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = targetFormat
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return (captureSession, device.localizedName)
    }

    private func observeSessionFailures(_ captureSession: AVCaptureSession) {
        removeSessionObservers()
        let center = NotificationCenter.default
        sessionObservers = NativeCameraSessionLifecycle.failureNotifications.map { name in
            center.addObserver(
                forName: name,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                self?.captureSessionFailed(notification)
            }
        }
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        for observer in sessionObservers {
            center.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }

    private func captureSessionFailed(_ notification: Notification) {
        stateLock.lock()
        let shouldTerminate = NativeCameraSessionLifecycle.shouldTerminateBridge(
            streaming: streaming,
            stopped: stopped
        )
        if shouldTerminate {
            streaming = false
        }
        stateLock.unlock()
        guard shouldTerminate else { return }

        let reason = notification.name == AVCaptureSession.runtimeErrorNotification
            ? "reported a runtime error"
            : "stopped unexpectedly"
        fputs("[camera-bridge] The Mac camera session \(reason); reconnecting.\n", stderr)
        // Closing the channel ends run(); the launcher then restarts this helper,
        // while the guest service reopens its side of the virtio port.
        stop()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        stateLock.lock()
        let shouldStream = streaming && !stopped
        stateLock.unlock()
        guard shouldStream,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        do {
            let payload = try copyNV12Payload(from: applyBackground(to: pixelBuffer))
            writeLock.lock()
            sequence &+= 1
            let message = NativeCameraWireFormat.message(
                kind: .frame,
                sequence: sequence,
                payload: payload
            )
            defer { writeLock.unlock() }
            try NativeBridgeSocket.writeAll(message, to: descriptor, label: "camera")
        } catch {
            stateLock.lock()
            let shouldReport = streaming && !stopped
            streaming = false
            stateLock.unlock()
            if shouldReport {
                fputs("[camera-bridge] \(error.localizedDescription)\n", stderr)
                stop()
            }
        }
    }

    /// A failing effect never stops the stream: the raw frame is sent and the
    /// effect is dropped for the rest of this bridge's life.
    private func applyBackground(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        stateLock.lock()
        let effect = backgroundEffect
        stateLock.unlock()
        guard let effect else { return pixelBuffer }
        do {
            return try effect.apply(to: pixelBuffer)
        } catch {
            fputs("[camera-bridge] camera background disabled: \(error.localizedDescription)\n", stderr)
            stateLock.lock()
            backgroundEffect = nil
            backgroundEffectFailed = true
            stateLock.unlock()
            return pixelBuffer
        }
    }

    private func copyNV12Payload(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let format = activeFormat
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              width == format.width,
              height == format.height,
              planeCount == 2 else {
            throw HelperError.io(
                String(
                    format: "the Mac camera produced format 0x%08x at %dx%d with %d planes",
                    pixelFormat,
                    width,
                    height,
                    planeCount
                )
            )
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        var payload = Data(count: format.frameBytes)
        try payload.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                throw HelperError.io("cannot allocate a camera frame")
            }
            var destinationOffset = 0
            for plane in 0..<2 {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                    throw HelperError.io("the Mac camera frame has no plane storage")
                }
                // NV12's chroma plane reports half the luma width in two-byte
                // samples, but both planes contain `width` packed bytes per row.
                let rowBytes = format.width
                let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let expectedRows = plane == 0 ? format.height : format.height / 2
                guard rows == expectedRows,
                      sourceStride >= rowBytes,
                      destinationOffset + rowBytes * rows <= destination.count else {
                    throw HelperError.io("the Mac camera frame has an unexpected plane layout")
                }
                for row in 0..<rows {
                    memcpy(
                        destinationBase.advanced(by: destinationOffset),
                        sourceBase.advanced(by: row * sourceStride),
                        rowBytes
                    )
                    destinationOffset += rowBytes
                }
            }
            guard destinationOffset == destination.count else {
                throw HelperError.io("the Mac camera frame is incomplete")
            }
        }
        return payload
    }

    private func sendStatus(_ fields: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let message = NativeCameraWireFormat.message(kind: .status, sequence: 0, payload: payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        try NativeBridgeSocket.writeAll(message, to: descriptor, label: "camera")
    }
}
