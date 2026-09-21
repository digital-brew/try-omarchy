import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native camera bridge")
struct NativeCameraBridgeTests {
    @Test("wire messages use the fixed little-endian virtio framing")
    func wireFraming() throws {
        let payload = Data([0xaa, 0xbb, 0xcc])
        let message = NativeCameraWireFormat.message(
            kind: .frame,
            sequence: 0x0102_0304,
            payload: payload
        )
        #expect(message.count == NativeCameraWireFormat.headerBytes + payload.count)
        #expect(Array(message.prefix(4)) == [0x54, 0x4f, 0x43, 0x4d])
        #expect(message[4] == NativeCameraWireFormat.version)
        #expect(message[5] == NativeCameraWireFormat.MessageKind.frame.rawValue)
        #expect(Array(message[8..<12]) == [3, 0, 0, 0])
        #expect(Array(message[12..<16]) == [4, 3, 2, 1])
        #expect(message.suffix(payload.count) == payload)
    }

    @Test("camera format defaults to 720p NV12")
    func defaultFormat() {
        let format = NativeCameraFrameFormat.default
        #expect(format.width == 1280)
        #expect(format.height == 720)
        #expect(format.framesPerSecond == 30)
        #expect(NativeCameraWireFormat.pixelFormat == "NV12")
        #expect(format.frameBytes == 1_382_400)
        #expect(format.captureSessionPreset == .hd1280x720)
        #expect(format.label == "1280x720@30")
        let settings = format.videoSettings()
        #expect(
            settings[kCVPixelBufferPixelFormatTypeKey as String] as? Int
                == Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        )
        #expect(settings[kCVPixelBufferWidthKey as String] as? Int == 1280)
        #expect(settings[kCVPixelBufferHeightKey as String] as? Int == 720)
    }

    @Test("camera format parses WIDTHxHEIGHT[@FPS] and rejects odd or absurd sizes")
    func parseFormat() {
        let vga = NativeCameraFrameFormat.parse("640x480@30")
        #expect(vga == NativeCameraFrameFormat(width: 640, height: 480, framesPerSecond: 30))
        #expect(vga?.frameBytes == 460_800)
        #expect(vga?.captureSessionPreset == .vga640x480)
        #expect(NativeCameraFrameFormat.parse(" 1920X1080 ")?.framesPerSecond == 30)
        #expect(NativeCameraFrameFormat.parse("1920x1080")?.captureSessionPreset == .hd1920x1080)
        #expect(NativeCameraFrameFormat.parse("848x480@24")?.captureSessionPreset == .high)
        #expect(NativeCameraFrameFormat.parse("960x540")?.captureSessionPreset == .qHD960x540)
        #expect(NativeCameraFrameFormat.parse("641x480") == nil)
        #expect(NativeCameraFrameFormat.parse("640x480@0") == nil)
        #expect(NativeCameraFrameFormat.parse("640x480@30@1") == nil)
        #expect(NativeCameraFrameFormat.parse("8000x480") == nil)
        #expect(NativeCameraFrameFormat.parse("720p") == nil)
        #expect(NativeCameraFrameFormat.parse("") == nil)
    }

    @Test("camera format prefers the environment, then the stored default, and warns on garbage")
    func configuredFormat() {
        #expect(
            NativeCameraFrameFormat.configured(environment: [:], storedValue: nil, warn: { _ in })
                == .default
        )
        #expect(
            NativeCameraFrameFormat.configured(
                environment: [NativeCameraFrameFormat.environmentKey: "640x480"],
                storedValue: "1920x1080",
                warn: { _ in }
            ).width == 640
        )
        #expect(
            NativeCameraFrameFormat.configured(environment: [:], storedValue: "1920x1080@30", warn: { _ in })
                .height == 1080
        )
        var warnings: [String] = []
        let fallback = NativeCameraFrameFormat.configured(
            environment: [:],
            storedValue: "huge",
            warn: { warnings.append($0) }
        )
        #expect(fallback == .default)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("huge") == true)
    }

    @Test("camera background parses none, blur with radius, and image paths")
    func backgroundParsing() {
        #expect(NativeCameraBackground.parse("none") == .none)
        #expect(NativeCameraBackground.parse("OFF") == .none)
        #expect(NativeCameraBackground.parse("blur") == .blur(radius: NativeCameraBackground.defaultBlurRadius))
        #expect(NativeCameraBackground.parse("blur:20") == .blur(radius: 20))
        #expect(NativeCameraBackground.parse("blur=4.5") == .blur(radius: 4.5))
        #expect(NativeCameraBackground.parse("blur:0") == nil)
        #expect(NativeCameraBackground.parse("blur:500") == nil)
        #expect(NativeCameraBackground.parse("blur:abc") == nil)
        #expect(NativeCameraBackground.parse("/tmp/office.jpg") == .image(URL(fileURLWithPath: "/tmp/office.jpg")))
        #expect(NativeCameraBackground.parse("image:/tmp/office.jpg") == .image(URL(fileURLWithPath: "/tmp/office.jpg")))
        #expect(NativeCameraBackground.parse("~/office.jpg")?.label.hasPrefix("image:/") == true)
        #expect(NativeCameraBackground.parse("office.jpg") == nil)
        #expect(NativeCameraBackground.parse("") == nil)
        #expect(NativeCameraBackground.blur(radius: 12.4).label == "blur:12")
        #expect(NativeCameraBackground.none.label == "none")
    }

    @Test("camera background prefers the environment, then the stored default, and warns on garbage")
    func configuredBackground() {
        #expect(NativeCameraBackground.configured(environment: [:], storedValue: nil, warn: { _ in }) == .none)
        #expect(
            NativeCameraBackground.configured(
                environment: [NativeCameraBackground.environmentKey: "blur"],
                storedValue: "/tmp/office.jpg",
                warn: { _ in }
            ) == .blur(radius: NativeCameraBackground.defaultBlurRadius)
        )
        var warnings: [String] = []
        #expect(NativeCameraBackground.configured(environment: [:], storedValue: "sparkles", warn: { warnings.append($0) }) == .none)
        #expect(warnings.count == 1)
    }

    @Test("guest requests carry the loopback geometry and may ask for a status refresh")
    func guestRequests() {
        let preferred = NativeCameraFrameFormat(width: 640, height: 480, framesPerSecond: 30)
        #expect(NativeCameraGuestRequest.parse(["type": "start"], preferred: preferred) == .start(preferred))
        #expect(
            NativeCameraGuestRequest.parse(["type": "start", "width": 1280, "height": 720], preferred: preferred)
                == .start(NativeCameraFrameFormat(width: 1280, height: 720, framesPerSecond: 30))
        )
        #expect(NativeCameraGuestRequest.parse(["type": "stop"], preferred: preferred) == .stop)
        #expect(NativeCameraGuestRequest.parse(["type": "status"], preferred: preferred) == .status)
        #expect(NativeCameraGuestRequest.parse(["type": "start", "width": 641, "height": 480], preferred: preferred) == nil)
        #expect(NativeCameraGuestRequest.parse(["type": "start", "width": 640], preferred: preferred) == nil)
        #expect(NativeCameraGuestRequest.parse(["type": "stop", "width": 640, "height": 480], preferred: preferred) == nil)
        #expect(NativeCameraGuestRequest.parse(["type": "reboot"], preferred: preferred) == nil)
        #expect(NativeCameraGuestRequest.parse(["width": 640], preferred: preferred) == nil)
    }

    @Test("active session failures reconnect the bridge")
    func sessionFailureRecovery() {
        #expect(
            NativeCameraSessionLifecycle.failureNotifications
                == [
                    AVCaptureSession.runtimeErrorNotification,
                    AVCaptureSession.didStopRunningNotification,
                ]
        )
        #expect(
            NativeCameraSessionLifecycle.shouldTerminateBridge(
                streaming: true,
                stopped: false
            )
        )
        #expect(
            !NativeCameraSessionLifecycle.shouldTerminateBridge(
                streaming: false,
                stopped: false
            )
        )
        #expect(
            !NativeCameraSessionLifecycle.shouldTerminateBridge(
                streaming: true,
                stopped: true
            )
        )
    }
}

@Suite("Camera launch policy")
struct CameraLaunchDecisionTests {
    @Test("denial keeps Omarchy launchable and gives recovery instructions")
    func deniedStillLaunches() {
        let decision = CameraLaunchDecision.make(for: .denied)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("continue without the Mac camera") == true)
        #expect(decision.warning?.contains("Privacy & Security > Camera") == true)
    }

    @Test("authorization launches without a warning")
    func authorizedHasNoWarning() {
        let decision = CameraLaunchDecision.make(for: .authorized)
        #expect(decision.allowsLaunch)
        #expect(decision.warning == nil)
    }

    @Test("an unrequested camera remains optional")
    func notDeterminedStillLaunches() {
        let decision = CameraLaunchDecision.make(for: .notDetermined)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("was not requested") == true)
    }
}
