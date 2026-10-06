# MemeCam virtual camera: research (2026-10-07)

Target: macOS 26.6, Apple Silicon, Xcode NOT installed (CLT + Swift 6.3.3), 0 codesigning identities
(`security find-identity -v -p codesigning` -> 0), SIP enabled, no known paid Apple Developer account.

## 0. Verdict

- The only supported virtual camera mechanism on macOS 14.1+ is a CoreMediaIO **Camera Extension**, a *system extension*.
- Installing one needs the restricted entitlement `com.apple.developer.system-extension.install`. Apple's capability table
  says **System Extension is available for ADP (paid) and Developer ID only, NOT for the free "Apple Developer" tier**
  (Personal Team). App groups are available to free accounts; System Extension is not.
  Source (table row checked in raw HTML): https://developer.apple.com/help/account/reference/supported-capabilities-macos/
- So without a paid account ($99/yr) the real extension cannot be shipped in a supported way. Unsupported escape hatch:
  disable SIP + AMFI (section 2). Practical free path today: **OBS virtual camera** (section 4).
- Xcode is not required (hand-assembled bundle works) but a provisioning profile is, and only a paid account issues one.

## 1. CMIOExtension architecture

### 1.1 Required structure
```
MemeCam.app/                                  (must live in /Applications, else
  Contents/MacOS/MemeCam                       OSSystemExtensionErrorUnsupportedParentBundleLocation)
  Contents/Info.plist                          NSSystemExtensionUsageDescription
  Contents/embedded.provisionprofile           (required for dev builds, see 2)
  Contents/Library/SystemExtensions/
    com.hexarch.memecam.CameraExtension.systemextension/   <- folder name MUST equal the bundle id
      Contents/MacOS/com.hexarch.memecam.CameraExtension
      Contents/Info.plist                      CFBundlePackageType=SYSX, CMIOExtension dict
```
Extension Info.plist keys: `CFBundlePackageType=SYSX`, `NSSystemExtensionUsageDescription`,
`CMIOExtension = { CMIOExtensionMachServiceName = "<TeamID>.com.hexarch.memecam" }`. The mach service name must start with
an app group the extension is in. Naming mismatch gives `OSSystemExtensionErrorExtensionNotFound` (code 4); confirmed by Apple DTS
in https://developer.apple.com/forums/thread/840312 (macOS 26.5.2 report).

Entitlements:
- Host app: `com.apple.developer.system-extension.install`, `com.apple.security.application-groups`
  (`<TeamID>.com.hexarch.memecam`), optional `com.apple.security.app-sandbox`, and
  `com.apple.security.device.camera` only if the app itself captures a camera.
- Extension: `com.apple.security.app-sandbox` + the same app group. (OBS's extension has exactly these two.)
Real files: OBS `plugins/mac-virtualcam/src/camera-extension/cmake/macos/entitlements.plist`; tethercam `mac-app/Extension/TetherCamCamera.entitlements`.

Activation (host): `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)`, delegate handles
`requestNeedsUserApproval` and `didFinishWithResult`. The user must then enable it in System Settings > General > Login Items &
Extensions > Camera Extensions (admin password, cannot be scripted). Updates replace the running build
(`actionForReplacingExtension -> .replace`); bump `CFBundleVersion` each build. Example: tethercam `ExtensionInstaller.swift`.

### 1.2 App -> extension transport: sink stream (recommended)
WWDC22 "Create camera extensions with Core Media IO" (session 10022) pattern: the device exposes a `.source` stream (what apps
read) plus a `.sink` stream. The app finds the device via the CMIO C API, copies the sink's `CMSimpleQueue`, starts the
stream and enqueues `CMSampleBuffer`s. The extension calls `consumeSampleBuffer(from:)` and re-emits via `source.stream.send(...)`.
Pixel data is IOSurface-backed `CVPixelBuffer`, so there is no CPU copy through the CMIO queue.
Why this beats the alternatives:
- XPC from app to extension: the extension sandbox/launchd context makes plain XPC awkward; forum thread
  https://developer.apple.com/forums/thread/706184 ("is XPC from app to CMIOExtension possible?") has no clean answer.
- App group files / shared memory: works but you must build framing, sync and pacing yourself.
Measured gotchas on macOS 26.6 (from tethercam `CMIOSink.swift`, same OS as ours):
1. `CMIOStreamCopyBufferQueue` needs a **non-nil** `queueAlteredProc`, otherwise it returns noErr and no queue.
2. App-side `kCMIOStreamPropertyDirection`: **0 = the extension's sink**, 1 = its source (inverted from the extension's view).
3. The delivered queue can be bigger than requested (asked 4, got 10). Check `CMSimpleQueueGetCount < Capacity` before enqueue.
4. `CMIOExtensionClient.signingID` was nil for the dev-signed host: do not gate the sink on signingID.
5. Enqueue with `Unmanaged.passRetained(sample)`; the extension owns the +1.

### 1.3 Skeleton (extension; untested here, no Xcode; modelled on OBS + tethercam)
```swift
// main.swift
import CoreMediaIO
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()

// Shared constants
enum Cfg {
  static let w: Int32 = 1280, h: Int32 = 720
  static let frameDuration = CMTime(value: 1, timescale: 30)
  static let deviceUID = "com.hexarch.memecam.device"        // used by the app to find the device
  static let deviceID = UUID(uuidString: "6B0C3C5A-1E6A-4D7B-9A55-2C1F0A0D0001")!
  static let sourceID = UUID(uuidString: "6B0C3C5A-1E6A-4D7B-9A55-2C1F0A0D0002")!
  static let sinkID   = UUID(uuidString: "6B0C3C5A-1E6A-4D7B-9A55-2C1F0A0D0003")!
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
  private(set) var provider: CMIOExtensionProvider!
  private let device = DeviceSource()
  init(clientQueue: DispatchQueue?) {
    super.init()
    provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
    try? provider.addDevice(device.device)
  }
  func connect(to client: CMIOExtensionClient) throws {}; func disconnect(from client: CMIOExtensionClient) {}
  var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
  func providerProperties(forProperties p: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
    let r = CMIOExtensionProviderProperties(dictionary: [:]); r.manufacturer = "hexarch"; return r }
  func setProviderProperties(_ p: CMIOExtensionProviderProperties) throws {}
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
  private(set) var device: CMIOExtensionDevice!
  private var source: CMIOExtensionStream!, sink: CMIOExtensionStream!
  private var sourceClients = 0, sinkClient: CMIOExtensionClient?
  private let q = DispatchQueue(label: "memecam.dev")
  override init() {
    super.init()
    var desc: CMFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
      width: Cfg.w, height: Cfg.h, extensions: nil, formatDescriptionOut: &desc)
    let fmt = CMIOExtensionStreamFormat(formatDescription: desc!, maxFrameDuration: Cfg.frameDuration,
      minFrameDuration: Cfg.frameDuration, validFrameDurations: nil)
    device = CMIOExtensionDevice(localizedName: "MemeCam", deviceID: Cfg.deviceID,
      legacyDeviceID: Cfg.deviceUID, source: self)
    let src = StreamSrc(fmt, owner: self), snk = StreamSnk(fmt, owner: self)
    source = CMIOExtensionStream(localizedName: "MemeCam Video", streamID: Cfg.sourceID,
      direction: .source, clockType: .hostTime, source: src)
    sink = CMIOExtensionStream(localizedName: "MemeCam Sink", streamID: Cfg.sinkID,
      direction: .sink, clockType: .hostTime, source: snk)
    try? device.addStream(source); try? device.addStream(sink)
  }
  var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
  func deviceProperties(forProperties p: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
    let r = CMIOExtensionDeviceProperties(dictionary: [:])
    if p.contains(.deviceTransportType) { r.transportType = 0x7669_7274 } // 'virt'
    if p.contains(.deviceModel) { r.model = "MemeCam" }
    return r }
  func setDeviceProperties(_ p: CMIOExtensionDeviceProperties) throws {}

  func sourceDidStart() { q.async { self.sourceClients += 1; self.pump() } }
  func sourceDidStop()  { q.async { self.sourceClients = max(0, self.sourceClients - 1) } }
  func sinkDidStart(_ c: CMIOExtensionClient?) { q.async { self.sinkClient = c; self.pump() } }
  func sinkDidStop()    { q.async { self.sinkClient = nil } }

  /// Forward sink -> source while someone reads the source and the app feeds the sink.
  private func pump() {
    guard sourceClients > 0, let c = sinkClient else { return }
    sink.consumeSampleBuffer(from: c) { [weak self] buf, seq, _, _, err in
      guard let self else { return }
      if let buf {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let ns = UInt64(now.seconds * 1_000_000_000)
        self.sink.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(
          sequenceNumber: seq, hostTimeInNanoseconds: ns))
        self.source.send(buf, discontinuity: [], hostTimeInNanoseconds: ns)
      }
      self.q.async { if err == nil { self.pump() } }
    }
  }
}

final class StreamSrc: NSObject, CMIOExtensionStreamSource {
  let fmt: CMIOExtensionStreamFormat; unowned let owner: DeviceSource
  init(_ f: CMIOExtensionStreamFormat, owner: DeviceSource) { fmt = f; self.owner = owner }
  var formats: [CMIOExtensionStreamFormat] { [fmt] }
  var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }
  func streamProperties(forProperties p: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
    let r = CMIOExtensionStreamProperties(dictionary: [:])
    r.activeFormatIndex = 0; r.frameDuration = Cfg.frameDuration; return r }
  func setStreamProperties(_ p: CMIOExtensionStreamProperties) throws {}
  func authorizedToStartStream(for c: CMIOExtensionClient) -> Bool { true }
  func startStream() throws { owner.sourceDidStart() }
  func stopStream() throws { owner.sourceDidStop() }
}

final class StreamSnk: NSObject, CMIOExtensionStreamSource {
  let fmt: CMIOExtensionStreamFormat; unowned let owner: DeviceSource
  private var client: CMIOExtensionClient?
  init(_ f: CMIOExtensionStreamFormat, owner: DeviceSource) { fmt = f; self.owner = owner }
  var formats: [CMIOExtensionStreamFormat] { [fmt] }
  var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration,
    .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData] }
  func streamProperties(forProperties p: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
    let r = CMIOExtensionStreamProperties(dictionary: [:])
    r.activeFormatIndex = 0; r.frameDuration = Cfg.frameDuration
    r.sinkBufferQueueSize = 4; r.sinkBuffersRequiredForStartup = 1
    r.sinkBufferUnderrunCount = 0; r.sinkEndOfData = 0; return r }
  func setStreamProperties(_ p: CMIOExtensionStreamProperties) throws {}
  func authorizedToStartStream(for c: CMIOExtensionClient) -> Bool { client = c; return true }
  func startStream() throws { owner.sinkDidStart(client) }
  func stopStream() throws { owner.sinkDidStop() }
}
```
Reference implementations of the same classes: OBS `OBSCameraProviderSource/DeviceSource/StreamSource/StreamSink.swift`
(https://github.com/obsproject/obs-studio/tree/master/plugins/mac-virtualcam/src/camera-extension),
Kanevry/tethercam `mac-app/Extension/{ProviderSource,DeviceSource,StreamSource,StreamSink}.swift` (MIT, macOS 26.6).

### 1.4 App-side sink feeder
```swift
import CoreMedia, CoreMediaIO, CoreVideo

final class SinkFeeder {
  private var device = CMIODeviceID(0), stream = CMIOStreamID(0)
  private var queue: CMSimpleQueue?
  private var fmt: CMVideoFormatDescription?
  func connect(deviceUID: String = "com.hexarch.memecam.device") throws {
    guard let dev = Self.ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
      .first(where: { Self.uid($0) == deviceUID }) else { throw NSError(domain: "sink", code: 1) } // ext not approved
    // App-side direction: 0 == extension's sink (measured on macOS 26.6)
    guard let sink = Self.ids(dev, kCMIODevicePropertyStreams).first(where: { Self.direction($0) == 0 })
    else { throw NSError(domain: "sink", code: 2) }
    var q: Unmanaged<CMSimpleQueue>?
    // altered proc MUST be non-nil or no queue is returned
    guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q) == noErr, let q
    else { throw NSError(domain: "sink", code: 3) }
    queue = q.takeRetainedValue()
    guard CMIODeviceStartStream(dev, sink) == noErr else { throw NSError(domain: "sink", code: 4) }
    device = dev; stream = sink
  }

  func push(_ pb: CVPixelBuffer) {          // BGRA 1280x720, IOSurface-backed
    guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return } // drop
    if fmt == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt) }
    var t = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt!,
      sampleTiming: &t, sampleBufferOut: &sb)
    guard let sb else { return }
    let p = Unmanaged.passRetained(sb)
    if CMSimpleQueueEnqueue(queue, element: p.toOpaque()) != noErr { p.release() }
  }

  func disconnect() { if stream != 0 { CMIODeviceStopStream(device, stream) }; queue = nil; stream = 0 }

  // --- CMIO helpers ---
  static func ids(_ obj: CMIOObjectID, _ sel: Int) -> [CMIOObjectID] {
    var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0, used: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &used, &out); return out }
  static func uid(_ dev: CMIOObjectID) -> String? {
    var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var s: Unmanaged<CFString>?; var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<CFString?>.size), &used, &s) == noErr else { return nil }
    return s?.takeRetainedValue() as String? }
  static func direction(_ st: CMIOObjectID) -> UInt32 {
    var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var d: UInt32 = 99, used: UInt32 = 0
    CMIOObjectGetPropertyData(st, &a, 0, nil, 4, &used, &d); return d }
}
```
Open-source feeders using the same calls: ldenoue/cameraextension `samplecamera/ViewController.swift` (`initSink`, `getCMIODevice`,
`getInputStreams`), tethercam `CMIOSink.swift`, alii/open-opal `VirtualCameraFeeder.swift`, steelbrain/LemurCam,
NewChromantics/PopKinectMacWebcam `SinkStreamPusher.swift`, abdulsaheel/beamcam `CMIOSinkClient.swift`, creativeIKEP/UniCamEx.

## 2. Signing without a paid account

| Question | Answer | Evidence |
|---|---|---|
| Free Apple ID / Personal Team gets System Extension capability? | **No.** Capability table: System Extension = ADP and Developer ID only; free "Apple Developer" column is blank. App groups: yes for free. | developer.apple.com/help/account/reference/supported-capabilities-macos (raw HTML row) |
| Is the entitlement restricted? | Yes, must be authorised by a provisioning profile; app+extension Team IDs must match; must be notarized or MAS for distribution. | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install and .redistributable |
| Ad-hoc signing (`codesign -s -`)? | Cannot carry a restricted entitlement: AMFI kills the process, and sysextd requires a valid Team ID. Not viable with SIP/AMFI on. | DTS (Quinn) on a similar case: https://developer.apple.com/forums/thread/825136 |
| `systemextensionsctl developer on`? | Relaxes sysext policy (e.g. app need not be in /Applications, replace without prompts). Community reports it needs SIP disabled. It does NOT mint entitlements. | forums 764939, 840312; hackmd.io/@QSquirrel/BJTEAwPzK |
| Disable SIP + AMFI (`csrutil disable`, `nvram boot-args=amfi_get_out_of_my_way=1`)? | Reported to let unsigned/self-claimed entitlements run. DTS: "not a supported configuration", may take hours, no guarantee. Needs Recovery boot on Apple Silicon (reduced security), weakens the whole machine. Untested here; this Mac has SIP enabled, no boot-args. | https://developer.apple.com/forums/thread/825136 |
| Build without Xcode (swiftc/SwiftPM + codesign + hand-made bundle)? | Technically yes: a `.systemextension` is just a Mach-O + Info.plist; `swiftc` builds it, `codesign --entitlements` signs it, `xcrun` is not needed. The blocker is not Xcode but the **provisioning profile** (`embedded.provisionprofile`), obtainable only via a paid account (Xcode automatic signing or the developer portal). Xcode adds nothing else mandatory. | tethercam notes: Developer ID builds worked with an embedded profile; its dev flow uses Xcode automatic signing (a paid team). |

Bottom line: **a paid account (Apple Developer Program) is effectively required**; Xcode is not. With one: create an App ID with
System Extension + App Groups, download a development profile (and register this Mac's UDID), embed it in app and extension,
sign with an "Apple Development" cert for local use, or "Developer ID Application" + notarization (`notarytool`) to give it to friends.
Without one the extension route means running with SIP/AMFI off, which we do not recommend on the daily machine.

## 3. Legacy DAL plug-ins
Not loadable. Apple deprecated DAL in 12.3 and **disabled DAL plug-ins completely in macOS 14.1**
(https://eclecticlight.co/2023/10/27/how-sonoma-14-1-could-stop-your-camera-working/). OBS < 30 virtual cam does not work on 14+
(https://obsproject.com/kb/virtual-camera-troubleshooting). Nothing indicates a return in 15 or 26. Also DAL in-process plug-ins
were already rejected by hardened-runtime apps (Discord, Zoom, Chrome) without library-validation exemptions. Do not pursue DAL.
Consequence: CamTwist, Syphon Virtual Webcam (DAL-based), old Snap Camera do not work on 26.6.

## 4. Fallbacks without a paid account
1. **OBS Studio 30+ (free, Developer ID signed + notarized, ships its own camera extension).** On macOS 13+: install OBS to
   /Applications, Start Virtual Camera, approve under Camera Extensions. Feed it from MemeCam via
   - *macOS Screen Capture / Window Capture* source pointed at a MemeCam output window (works now, any app, 1:1 pixels;
     crop to 1280x720, hide cursor, keep the window unobscured/on-screen; mind capture-permission prompts);
   - or Syphon / NDI plugins (obs-syphon, DistroAV) if MemeCam publishes frames that way.
   Cost: two apps, OBS must stay running, +1 frame latency. OBS is not installed on this Mac (Discord and Telegram are).
   Best no-cost path today. Installing via `brew install --cask obs` is enough.
2. NDI: NDI Tools "Virtual Input" is reported to work as a macOS camera (community reports on cdm.link/TroikaTronix); verify it ships a Camera Extension
   on 26 before relying on it. MemeCam would need the proprietary NDI SDK to publish, which adds a dependency.
4. If SIP-off is acceptable on a *secondary* Mac: our own extension + `developer on` (unsupported, see 2).
Recommended plan: build MemeCam to render into a fixed-size output (1280x720 BGRA) behind a `FrameSink` protocol; ship an
OBS-window-capture backend now and a CMIO sink backend (section 1) once a paid account exists, no UI change.

## 5. Client compatibility with Camera Extensions
Camera extensions run out-of-process, so host-app hardened runtime/library validation no longer matters (the main reason DAL cams
broke in Discord/Zoom/Chrome). Status for our clients:
- **Chrome / Chromium**: sees them (OBS KB says the new component "is compatible with all Mac applications"; Chromium also worked with the old DAL cam).
  Tested clients in tethercam spec (macOS 26.6): Chrome `enumerateDevices`/getUserMedia, Safari, FaceTime, Photo Booth, QuickTime, ffmpeg avfoundation.
- **Safari**: works (tethercam Safari run); Safari needs per-site camera permission.
- **Zoom, Teams, Meet(Chrome)**: documented as working with OBS 30 camera extension; Zoom/Teams untested in tethercam.
- **Discord desktop**: historic 2021 problem was DAL + library validation
  (https://support.discord.com/hc/vi/community/posts/4417259853591-Support-for-macOS-Virtual-Cameras). Not re-verified on 26.6;
  the extension model removes that cause. Known user workaround for stale DAL cams: `codesign --remove-signature` on Discord Help, not needed for extensions.
- **Telegram Desktop**: no authoritative data found for extension cameras. Test on this Mac (installed). Check Settings > Calls > Camera.
General issues: camera appears only after the user enables it in System Settings; apps started before activation may need restart
(cached device list); clients that cache by UID need a stable `deviceID`/`legacyDeviceID`; Apple Silicon/macOS 26.5 sysextd "no policy" log is noise
(thread 840312); `signingID` is nil on dev builds; apps requesting the camera still need TCC permission to the virtual camera.

## 6. Next steps
Decide ADP ($99/yr) vs OBS fallback. Install OBS and verify Discord + Telegram see it on 26.6 (settles section 5). Keep ids:
app `com.hexarch.memecam`, ext `com.hexarch.memecam.CameraExtension`, group `<TeamID>.com.hexarch.memecam`.
