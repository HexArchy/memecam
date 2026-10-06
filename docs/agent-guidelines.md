# Agent guidelines: memecam (SwiftUI, Swift 6, macOS 26)

Project skills live in `.claude/skills/` (`swiftui-expert-skill`, `swift-concurrency`, `swiftui-pro`).
Load them when touching SwiftUI / concurrency code. This file is the short checklist; skills have depth.
Verify any API against current Apple docs or the SDK before using it; do not guess signatures.

## 0. Project setup
- Swift language mode 6 (strict concurrency = complete), deployment target macOS 26; if macOS 15 is also
  supported, gate every macOS 26 API with `#available(macOS 26, *)` and give a material fallback.
- Consider Swift 6.2 "approachable concurrency": default actor isolation `MainActor` for the app target,
  `nonisolated` / `@concurrent` for background work. Keep the camera extension target on its own settings.
- Targets: app, CMIO camera extension (system extension), shared Swift package for pure models/types.
- Build and run tests after changes (`xcodebuild` / `swift test`); treat concurrency warnings as errors.

## 1. Swift 6 concurrency: AVCaptureSession + Vision
- `AVCaptureSession` is not Sendable. Own it in ONE place: an actor (`actor CameraEngine`) or a class with
  a dedicated serial `DispatchQueue` exposed via a custom `SerialExecutor` (`unownedExecutor`).
- `startRunning()` / `stopRunning()` / `beginConfiguration()` block: never call them on the main actor.
- Sample-buffer delegate (`AVCaptureVideoDataOutputSampleBufferDelegate`) is called on the queue you pass
  to `setSampleBufferDelegate`. Mark the delegate class `nonisolated`/`@unchecked Sendable` ONLY with a
  documented invariant (all state confined to that queue), and prefer `final class` + a lock or the actor.
- `CMSampleBuffer` / `CVPixelBuffer` are not Sendable. Do not send them across actors raw. Options:
  wrap in `struct FrameBox: @unchecked Sendable` with a comment, or use `sending` parameters, or process the
  frame fully inside the capture queue and only emit small Sendable results (`[FaceObservation]` structs).
- Bridge frames to async code with `AsyncStream<Frame>` using `bufferingPolicy: .bufferingNewest(1)` to drop
  stale frames (never let an unbounded buffer grow). Set `alwaysDiscardsLateVideoFrames = true`.
- Vision: create requests/handlers off the main actor. Reuse `VNSequenceRequestHandler` per stream (needed
  for tracking requests). Prefer the modern Swift API (`DetectFaceRectanglesRequest`, `DetectHumanHandPoseRequest`,
  `perform(on:)` async) on macOS 15+; fall back to `VN*` classes only if a needed request is missing.
- Run Vision at a lower rate than capture (e.g. every 2nd-3rd frame or max 15-30 Hz); reuse the last result
  between runs. One in-flight Vision job at a time; skip frames while busy.
- Publish results to UI as value types: `await MainActor.run { model.faces = result }` or have the
  `@MainActor @Observable` model consume an `AsyncStream` in a `.task {}`.
- Structured concurrency first: `.task {}` is cancelled with the view; store `Task` handles for long
  lived work and cancel them in `stop()`. Avoid `Task.detached` unless isolation must be dropped.
- Permissions: `await AVCaptureDevice.requestAccess(for: .video)`; handle `.denied`/`.restricted`; add
  `NSCameraUsageDescription` and sandbox entitlement `com.apple.security.device.camera`.
- Observe `AVCaptureDevice.RotationCoordinator`, `AVCaptureSession.wasInterrupted`, device connect/disconnect
  (`AVCaptureDevice.DiscoverySession` KVO / notifications) and recover; never assume the camera exists.
- Never use `DispatchQueue.main.async` with captured non-Sendable state; use `@MainActor` closures.

## 2. Observation and @MainActor UI patterns
- Models: `@MainActor @Observable final class AppModel`. In views: `@State private var model = AppModel()` for
  owner, plain `let`/`var` or `@Bindable` for injected, `@Environment(AppModel.self)` for shared. No
  `ObservableObject`/`@Published`/`@StateObject` in new code.
- Keep `body` cheap: no formatting, filtering, or allocation of heavy objects; extract subviews; pass only
  the data a subview needs (narrow dependencies). Use `let` for constants.
- Split models by update rate: a high-frequency model (face boxes, per-frame) separate from settings, so a
  60 Hz change does not invalidate the whole window.
- Use `@AppStorage` / `@SceneStorage` for simple prefs; `Codable` + file storage for effect presets.
- Async work in views via `.task(id:)`; never `Task {}` inside `body` or `onAppear` without cancellation.
- `foregroundStyle` not `foregroundColor`; `clipShape(.rect(cornerRadius:))`; `Button` with action, not
  `onTapGesture`; `NavigationStack`/`NavigationSplitView`, not `NavigationView`; `onChange(of:) { old, new in }`.
- Accessibility: labels for icon-only buttons, respect Reduce Motion / Reduce Transparency, Dynamic Type,
  keyboard navigation and focus (`@FocusState`, `.focusable`), VoiceOver for overlays.

## 3. macOS-native UI conventions
- Window structure: `NavigationSplitView` (sidebar: effects/scenes, detail: preview) plus `.inspector(isPresented:)`
  for per-effect settings. Persist inspector/sidebar state with `@SceneStorage`.
- Toolbar: `.toolbar { ToolbarItem(placement: .primaryAction) ... }`, `ToolbarSpacer` to group items on
  macOS 26, `.searchable` where relevant, `Menu` for overflow. Give each item a `help()` tooltip and label.
- Commands: provide real menu items with keyboard shortcuts via `.commands { CommandGroup / CommandMenu }`
  (start/stop camera, toggle effect, toggle preview). Mac users expect menus and shortcuts.
- `Settings { ... }` scene (Cmd+,) with `TabView`/`Form` using `.formStyle(.grouped)`; `Window` scene for
  single-instance utility windows; `MenuBarExtra` for quick toggle (`.menuBarExtraStyle(.window)` for rich UI;
  add `LSUIElement` only if the app is truly menu-bar-only; use `isInserted:` binding to let users hide it).
- SF Symbols: `Image(systemName:)`, `Label("Title", systemImage:)`; use symbol rendering modes and
  `symbolEffect` sparingly; check symbol availability per OS version.
- Layout: respect window resizing (`minWidth`/`idealWidth`, `.frame(maxWidth: .infinity)`), avoid
  hard-coded sizes; use semantic colors (`.primary`, `.secondary`, `Color(nsColor:)`) so dark mode works.
- Camera preview: wrap `AVCaptureVideoPreviewLayer` in an `NSViewRepresentable` (layer-backed view), or draw
  processed frames through `MTKView`/`CALayer`; update in `updateNSView` without re-creating the layer.
- AppKit interop only when SwiftUI lacks the feature (`NSViewRepresentable`, `NSApplicationDelegateAdaptor`).

## 4. Materials and Liquid Glass (macOS 26)
- Standard system chrome (toolbar, sidebar, sheets, controls) adopts Liquid Glass automatically when built
  with the macOS 26 SDK. Do NOT add glass to content or stack glass on glass; glass is for the controls
  layer floating above content (e.g. overlay HUD on the camera preview).
- API: `.glassEffect(.regular, in: .rect(cornerRadius: 16))`, `.regular.tint(...)`, `.interactive()` only on
  tappable elements; wrap several glass views in `GlassEffectContainer(spacing:)`; morph with
  `glassEffectID(_:in:)` + `@Namespace`; button styles `.glass` / `.glassProminent`.
- Modifier order: apply `.glassEffect` AFTER layout/padding/frame modifiers.
- Fallback pattern (when deployment < 26):
  ```swift
  extension View {
      @ViewBuilder func hudBackground() -> some View {
          if #available(macOS 26, *) { glassEffect(.regular, in: .rect(cornerRadius: 14)) }
          else { background(.regularMaterial, in: .rect(cornerRadius: 14)) }
      }
  }
  ```
- Older materials: `.background(.ultraThinMaterial)`, `.bar`, `.regularMaterial`; sidebars use
  `.listStyle(.sidebar)` for automatic vibrancy. Use `.backgroundExtensionEffect()` / scroll edge effects
  per skill refs rather than custom blur hacks.
- Respect Reduce Transparency; verify legibility over bright and dark video backgrounds.

## 5. Virtual camera (CoreMediaIO camera extension)
- Use `CMIOExtensionProvider` / `CMIOExtensionDevice` / `CMIOExtensionStream` (source stream for apps, optional
  sink stream to receive frames from the main app). Extension runs in its own process, sandboxed, as a
  system extension: activate from the app with `OSSystemExtensionRequest.activationRequest` and handle the
  delegate (needs user approval in System Settings, `com.apple.developer.system-extension.install`).
- Extension has no UI and a strict memory/CPU budget; keep it tiny: receive frames, convert, send. Do the
  Vision/effects work in the app and pass frames via the sink stream (or shared IOSurface-backed buffers).
- Provide fixed supported formats (`CMIOExtensionStreamFormat`), correct timing (`CMSampleBuffer` PTS from
  host clock), and a placeholder frame when no source is connected.
- Share config between app and extension via an App Group container; same team ID, matching entitlements.
- Test by launching FaceTime/Zoom/QuickTime; check logs: `log stream --predicate 'subsystem == "..."'`.

## 6. Performance
- Pixel format: request `kCVPixelFormatType_32BGRA` (or NV12 and convert on GPU); avoid CPU copies;
  prefer `CVMetalTextureCache` + Metal / Core Image (`CIContext` created once, Metal-backed) for effects.
- Choose the smallest session preset / format that fits (`.hd1280x720`); lower resolution for Vision input.
- Never allocate per frame in hot loops (reuse `CIContext`, buffers via `CVPixelBufferPool`).
- Throttle UI updates (<= 30-60 Hz), draw overlays in `Canvas` instead of hundreds of views.
- Profile with Instruments (Time Profiler, SwiftUI template, Metal System Trace, Allocations); check thermal
  state on M1 (8 GB): watch memory, avoid retaining frame buffers (leaks stall the capture pool).
- `Self._printChanges()` temporarily to debug redundant body evaluations.

## 7. Common pitfalls
- Starting/stopping the session on the main thread (UI hangs) or configuring without begin/commitConfiguration.
- Retaining `CMSampleBuffer`s beyond the delegate callback (capture pool starvation, dropped frames).
- Using `@unchecked Sendable` or `nonisolated(unsafe)` to silence errors without a confinement invariant.
- `DispatchQueue.main.async` + `Task` mixing; unstructured `Task {}` that is never cancelled.
- Updating `@Observable` state from the capture queue (must hop to `@MainActor`).
- Applying glass to everything, nesting glass, or using it without a fallback for older macOS.
- Forgetting entitlements/Info.plist keys (camera, system extension, app group) -> silent failures.
- Hand-rolled NSWindow/Menu code where SwiftUI scenes/commands exist; hard-coded colors; fixed window sizes.
- Deprecated APIs: `ObservableObject`, `NavigationView`, `foregroundColor`, `cornerRadius()`, `onChange` 1-arg.

## Sources
- AvdLee SwiftUI Agent Skill: https://github.com/AvdLee/SwiftUI-Agent-Skill
- AvdLee Swift Concurrency Agent Skill: https://github.com/AvdLee/Swift-Concurrency-Agent-Skill
- Paul Hudson SwiftUI Pro skill: https://github.com/twostraws/SwiftUI-Agent-Skill
- Liquid Glass skills (not vendored, for reference): https://github.com/haider-nawaz/liquid-glass-skill , https://github.com/YordiLorenzo/liquid-glass-skills
- Apple, Applying Liquid Glass to custom views: https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views
- Apple, Adopting Liquid Glass: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
- Apple, AVCam sample / capture setup: https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app
- Apple, Vision framework: https://developer.apple.com/documentation/vision
- Apple, Creating a camera extension with Core Media I/O: https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
- Apple, Swift concurrency / Sendable: https://developer.apple.com/documentation/swift/concurrency
- Apple HIG, macOS: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
- Swift Concurrency Course: https://www.swiftconcurrencycourse.com
