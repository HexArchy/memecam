# Quality backlog: robustness, concurrency, energy, security, l10n

Audit of v1.0.2 (2026-10-07), read-only; `swift build` has no warnings and `scripts/test.sh` passes 23/23. Line numbers are from
the audit-time tree. No Critical findings: nothing loses data or opens a remote attack surface. High = crashes, hangs, dead feeds, energy drain.

## High

**H1. Data races on plain properties shared between main and the capture/vision queues.**
- `MemePipeline.running`: written on main (`MemePipeline.swift:134`, `:139`), read on the capture queue (`:146`, `:154`).
- `CameraCapture.currentDeviceName` (a `String`): written on main (`CameraCapture.swift:67`), read on the capture
  and vision queues (`MemePipeline.swift:155`, `:159`, `:274`, `:361`). A torn `String` read while switching cameras
  can crash. That is undefined behaviour, and the `@unchecked Sendable` on both classes hides it from the compiler.
- `VisionDetector.detectHands`: written on main (`MemePipeline.swift:179`), read on the vision queue (`VisionDetector.swift:48`).
  The doc comment at `VisionDetector.swift:14` claims the detector is "called only from the capture queue". It actually runs on `visionQueue`.
- Fix: move `running`, the device name and the hand flag into the existing `state` lock (or a small
  `OSAllocatedUnfairLock<CameraInfo>`). Pass `detectHands` as a `detect(_:timestamp:detectHands:)` argument
  that is read from `State` under the lock. Then document the confinement invariant on each `@unchecked Sendable` type.

**H2. The capture session is configured on the main thread and blocks it.** `AppModel.start` (`AppModel.swift:172`) and
`restartIfRunning` (`:218`) call `MemePipeline.start`, which runs `camera.queue.sync` (`MemePipeline.swift:127`) and then
`CameraCapture.start`. That `start` does `begin/commitConfiguration`, `removeInput`/`addInput` and `lockForConfiguration`
on main (`CameraCapture.swift:50-73`, `:75-93`), while `startRunning`/`stopRunning` run on `queue` (`:71`, `:118`).
Switching to a Continuity iPhone takes 0.3–1 s, and the UI hangs (spinning beachball) during the commit. This also
breaks the project rule "never on the main actor" (agent-guidelines §1).
- Fix: make `CameraCapture.start(deviceID:) async throws` and do everything on `queue`
  (`withCheckedThrowingContinuation { queue.async { … } }`). The session is then touched from only one queue.

**H3. A failed camera switch leaves a dead feed that still reports "running".** `restartIfRunning` swallows errors with
`try?` (`AppModel.swift:218`). `configure` removes the old input before it creates the new one (`CameraCapture.swift:80-83`).
So if `AVCaptureDeviceInput(device:)` throws (camera busy) or `canAddInput` fails, the session has no input, the state
stays `.running`, and the stage freezes. The only explanation is the watchdog's "isn't sending video" after 3 s. If the new camera
is suspended (lid closed, `:53`), the old camera keeps running while the picker shows the new one.
- Fix: inside `configure`, add the new input before you remove the old one, or roll back to the previous input on failure.
  Have `restartIfRunning` set `cameraState = .failed(msg)` on error and restore the previous `selectedCameraID`.

**H4. The chosen camera is forgotten when it is absent at launch.** `init` calls `refreshCameras()` (`AppModel.swift:158`),
which sets `selectedCameraID = nil` when the device is not connected (`:201`). Its `didSet` then persists `nil` (`:30`, `:234`).
Launch MemeCam with the iPhone in another room, and the Continuity preference is permanently reset to "Default".
- Fix: keep the persisted *preferred* ID separate from the *effective* device. Fall back at start time without
  clearing the preference, and show "iPhone (not connected)" in `CameraMenu`.

**H5. No recovery from unplug, Continuity disconnect, wake or a session runtime error.** `observeSession` (`CameraCapture.swift:100-115`)
only maps the notifications to text. Nothing observes `AVCaptureDevice.wasConnectedNotification`/`wasDisconnectedNotification`
or `NSWorkspace.didWakeNotification`, and nothing restarts the session after `runtimeErrorNotification` (the session stops). Scenario: a
Continuity iPhone walks away mid-call. The virtual camera shows the "paused" placeholder forever, the camera list is
stale (it refreshes only on start or by hand, `AppModel.swift:170`, `CameraMenu.swift:23`), and nothing switches back when the phone returns.
- Fix: in `AppModel`, observe connect and disconnect, then call `refreshCameras()`. If the active device left, fall back to
  `defaultDevice()` while you keep the preference (H4), and switch back when it reconnects. On a runtime error or on wake with stale
  frames (more than 3 s), restart once on `queue`, with backoff.

**H6. The meme cache can use hundreds of MB.** `AnimatedImage` decodes up to 400 frames at ≤540 px, fully, with
`ShouldCacheImmediately` (`MemeLibrary.swift:48-68`). The LRU is bounded by count (8) rather than bytes (`:268`). Bundled
`noFace_cat_1.gif` is 104 frames × 340×385 × 4 B ≈ 54 MB, so eight such entries take about 300 MB. A user GIF with 400 frames at 540 px
takes about 470 MB on its own. On 8 GB machines this triggers memory pressure next to Zoom or a browser.
- Fix: give the cache a byte budget (Σ `bytesPerRow*height`, e.g. 120 MB) and evict by recency (on a hit, move the
  id to the end; at the moment, hits do not refresh the order). Cap frames at about 150 and subsample long GIFs (keep every n-th
  frame and sum the delays). Lower `maxPixelSize` to 360 for PiP. Measure the effect with the Allocations instrument or `footprint MemeCam`.

**H7. Vision runs at the full camera rate and repeats face detection.** `runVisionIfIdle` (`MemePipeline.swift:250-259`)
starts a new job as soon as the last one ends, so it runs at about 30 Hz. Each job runs `VNDetectFaceRectanglesRequest` *and*
`VNDetectFaceLandmarksRequest` (`VisionDetector.swift:49`), so the face is detected twice per frame. Hands run every 2nd
frame. The stabilizer needs about 0.5 s of votes, and 15 Hz is plenty for it (agent-guidelines §1).
- Fix: (a) gate Vision to 15 Hz (`now - lastVisionStart >= 1/15`). (b) Run the rectangles request first and set
  `faceRequest.inputFaceObservations` from its results, so landmarks skip detection, and skip landmarks when no face is found.
  (c) Drop to 8 Hz when `quietMode` and neutral. Measure with `inferenceMs` (already in the status), `powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000`,
  and Activity Monitor's Energy tab. Target: at least 30 % lower package power while running.

**H8. The pipeline never idles.** The camera, Vision and the compositor keep running at 30 fps while the window is closed,
hidden or minimised (the app lives on in the `MenuBarExtra`) and no app reads the virtual camera. `PreviewSink` keeps
enqueueing to an invisible layer (`FrameSink.swift:35-47`). `AppModel.status` changes 10×/s and invalidates views (`AppModel.swift:146-148`).
- Fix: add a `consumerActive` signal. Read `kCMIODevicePropertyDeviceIsRunningSomewhere` on the MemeCam device from `io`
  (or a custom extension property that reports `sourceClients`). Combine it with window occlusion (`NSWindow.occlusionState`) or the scene phase.
  When neither is true: stop Vision and the preview, and composite at 5 fps (or stop the camera after 30 s; the green LED then turns off).
  Pause `onStatus` while the window is not visible.

**H9. The virtual camera extension busy-polls at 200 Hz while the app is open with the camera stopped.** The app's sink stays
connected once frames have flowed: `tick` only disconnects on a stall *while frames flow* (`VirtualCameraSink.swift:130-136`).
Meanwhile the extension's `consume` loop retries every 5 ms when the queue is empty (`DeviceSource.swift:129-134`). That is
about 200 wake-ups/s in the extension for as long as MemeCam stays open idle. Verify with `top -stats pid,command,cpu,idlew` or Activity Monitor › Idle Wake Ups.
- Fix: in `tick`, disconnect when `stream != 0 && !framesFlowing` for more than 2 s (connect is already lazy). In the
  extension, back off exponentially (5 ms → 100 ms) while consecutive consumes return nil, and reset the backoff on the first buffer.

**H10. The update swap script breaks on paths that contain `'`.** `DEST='\(dest)'` and `NEW='\(newApp.path)'` are interpolated into
shell source (`Updater.swift:194-207`), and the launcher is `sh -c "nohup /bin/sh '\(script.path)' …"` (`:211`). An app at
`~/Nikita's Apps/MemeCam.app` produces a syntax error. Because the output is sent to `/dev/null`, the app quits and never relaunches, with no
message. A crafted folder name could also inject commands (self-inflicted, but still a shell-injection pattern).
- Fix: write a constant script that reads `"$1"…"$4"` (pid, dest, new, work) and start it with
  `Process(executableURL: /bin/sh, arguments: [script, pid, dest, new, work])` plus `setsid`/`nohup` via `posix_spawn`
  attributes, or use `/usr/bin/nohup` as the executable. Redirect its output to `~/Library/Logs/MemeCam/update.log`. On the next launch, if
  `$DEST.old` exists, report that the update failed.

**H11. The updater blocks the main actor for seconds.** `verify` runs on `@MainActor` (`Updater.swift:132`). It does
`SecStaticCodeCheckValidity` with `kSecCSCheckNestedCode`, which hashes the whole bundle including the extension, and then runs `spctl --assess`,
which can do an online notarization lookup with no timeout. `scheduleSwapAndRelaunch` calls `waitUntilExit` (`:213`). `run()` reads
the pipe only *after* `waitUntilExit` (`:224-226`), so a tool that writes more than 64 KB deadlocks. `hdiutil attach` has no
`stdin` (`:145`); a DMG with a licence agreement waits for input forever.
- Fix: run `extractApp` + `verify` + script creation in one `Task.detached`/`@concurrent` function. Read the pipe before
  `waitUntilExit` (or use `readabilityHandler`), set `standardInput = FileHandle.nullDevice`, and add a 60 s
  timeout that terminates the tool.

## Medium

**M1. Duplicate watchdog chains.** `start()` calls `startWatchdog()` every time (`MemePipeline.swift:135`), and each chain
re-arms itself while `running` (`:144-150`). Every camera switch while running, and every stop+start within 1 s, adds a
permanent extra 1 Hz chain. Fix: use a single `DispatchSourceTimer` on `camera.queue`, created once and resumed or suspended.

**M2. Any local process can feed the "MemeCam" camera.** `SinkStreamSource.authorizedToStartStream` returns `true`
for every client (`StreamSources.swift:79-82`), and a second client silently replaces the first (`DeviceSource.swift:92-96`).
Malware without camera access could inject video into your Zoom call. Fix: in Release builds, accept only clients whose
code signature matches `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>"`. Use
`SecCodeCopyGuestWithAttributes` with the client's audit token or pid. The pid route is racy, so prefer the audit token if CMIO exposes it.
Reject a second sink client while one is active.

**M3. App Nap and timer coalescing while hidden (verify).** Nothing calls `ProcessInfo.beginActivity`. With the window
hidden, the 0.5 s sink tick, the watchdog and capture-queue QoS can be throttled, and the virtual camera may stutter in a call. Check
the "App Nap" column in Activity Monitor during a Zoom call with MemeCam hidden. Fix: hold
`beginActivity(options: [.userInitiated, .latencyCritical])` while the sink is `.streaming` and a consumer is active (H8); release it otherwise.

**M4. No response to thermal pressure or Low Power Mode.** Nothing reads `ProcessInfo.thermalState` or `isLowPowerModeEnabled`.
Fix: observe `thermalStateDidChangeNotification` and `NSProcessInfoPowerStateDidChange`. At `.serious` or in low power: Vision at 8 Hz,
hands every 3rd frame, no backdrop blur in `fitWithBackdrop` (`Compositor.swift:175-191`). At `.critical`: capture at 15 fps
(`activeVideoMinFrameDuration`, `CameraCapture.swift:60-66`). Expose a status hint.

**M5. An app update replaces the extension during a call.** When versions differ, `handleProperties` calls `install()` immediately
(`VirtualCameraController.swift:186-190`). If Zoom is using MemeCam at that moment, the device disappears. Fix: defer the
replacement while `kCMIODevicePropertyDeviceIsRunningSomewhere` is true. Retry when it turns false, or on the next launch.

**M6. User-library file handling.**
- Path traversal: `user.json` entries are joined to `userDirectory` without validation (`MemeLibrary.swift:215`), and
  `remove` deletes `userDirectory/<file>` (`:164-165`). A tampered or corrupted manifest with `../…` makes "Remove" delete outside the
  folder. Fix: accept an entry only if `file == URL(filePath: file).lastPathComponent` and it has no `..`. Also check
  `resolvingSymlinksInPath()` stays under `userDirectory`.
- `addMemes` runs on main (`AppModel.swift:97-104`). It decodes and copies files of unbounded size there (`MemeLibrary.swift:145-158`).
  Drops of non-file URLs (`ReactionStrip.swift:95-99`) reach `CGImageSourceCreateWithURL`/`copyItem`. Fix: filter
  `isFileURL`, reject files over 50 MB or with more than 100 MP, and copy on a background task.
- If `save()` fails after `copyItem`, the in-memory entry is kept while the file is orphaned (`:152-157`). The `!` at `:158` assumes
  `rebuild` succeeded. Fix: roll back the entry and delete the copy on failure, and return the `Meme` built locally.

**M7. Updater state machine gaps.** `installUpdate` has no re-entrancy guard (`Updater.swift:119-121`); a double click downloads twice.
The work directory is never removed on failure (`:123`), which leaves a DMG of about 50 MB in `$TMPDIR` each time. If `NSApp.terminate` is
cancelled, the state stays `.installing` forever (`:134`). There is no download timeout or progress. Fix: guard on `.downloading/.installing`,
use `defer` to clean up on error, use `URLSession` with a delegate for progress and `timeoutIntervalForResource = 600`, and reset the state if the app
is still alive 10 s after `terminate`.

**M8. Localisation is blocked by `String`-typed UI text.** Literals in `Text("…")`, `Button("…")` and `.help("…")` are
`LocalizedStringKey`s and will localise. These, however, are plain `String`s, which SwiftUI shows verbatim:
`VirtualCameraState.title` (`VirtualCameraController.swift:23-33`), `OutputLayout.title` (`Compositor.swift:11-17`),
`AnimalFilter.title` (`MemeLibrary.swift:16-22`), `Reaction.title` (`MemeCamCore/Reaction.swift`), camera issues
(`MemePipeline.swift:155-160`), and the errors in `CameraCapture.swift:130-137`, `Updater.swift:241-247`, `SystemExtensionRequests.swift:68-95`,
`MemeLibrary.swift:228`, `UpdateButton.swift:28-36` and `CameraMenu.swift:39`. Plan (works with SwiftPM + CLT and no Xcode):
1. Return `String(localized: "…")` (or `LocalizedStringResource`) from these properties; use the default `bundle: .main`, which is also fine
   in `MemeCamCore`.
2. Ship `Resources/Localization/{en,ru}.lproj/Localizable.strings` (classic `"key" = "value";`, UTF-8, validated with
   `plutil -lint`) and `ru.lproj/InfoPlist.strings` (`NSCameraUsageDescription`, `NSSystemExtensionUsageDescription`, `CFBundleDisplayName`).
   Copy them in `build-app.sh` next to `Memes` (`:76-77`). SwiftUI resolves keys against `Bundle.main`, which is the .app, so
   `Contents/Resources/ru.lproj` is all that is needed.
3. Add `CFBundleLocalizations` = `[en, ru]` to the Info.plist heredoc (`build-app.sh:85-110`) and the extension template.
4. Do **not** add `resources:`/`defaultLocalization` to the executable target unless `build-app.sh` also copies
   `MemeCam_MemeCam.bundle`. The generated `Bundle.module` accessor calls `fatalError` when the bundle is missing in the .app.
5. The CLT has neither `xcstringstool` nor `genstrings` (checked), so `.xcstrings` cannot be compiled. Keep `.strings` and add a
   `scripts/check-strings.sh` that greps `Text("`/`String(localized:` keys and diffs them against `ru.lproj`. Interpolations become
   `%@`/`%lld` keys (for example `"Update %@"`). Meme titles burned into the video come from `memes.json` and need their own `title_ru`.
6. Test with `open MemeCam.app --args -AppleLanguages "(ru)"`.

## Low

- **L1** The vision queue holds the `state` unfair lock while it runs `classify`, `GuidedSession.record` and `library.pick` (NSLock, nested), at
  `MemePipeline.swift:263-288` and `:308`. The capture queue waits on it every frame. Fix: compute `est` outside the lock, then take the lock only to apply the result.
- **L2** `averageBrightness` does a synchronous GPU readback on the capture queue every second (`Compositor.swift:135-143`,
  `MemePipeline.swift:215-221`). Fix: render the 1×1 area-average asynchronously into a reusable `CVPixelBuffer`.
- **L3** `VirtualCameraSink` runs a 0.5 s timer forever and scans every CMIO device over IPC every 2 s, even though the devices listener
  covers that case (`VirtualCameraSink.swift:118-121`, `:143-148`). Fix: suspend the timer while no frames flow and the device state is known.
- **L4** `didBecomeActive` → `refresh()` queries sysextd on every activation (`VirtualCameraController.swift:84-88`); throttle to 1/30 s.
- **L5** `persistAndPush` writes 11 defaults keys on every slider tick (`AppModel.swift:221-235`). `load` does not clamp `sensitivity`, `calmness` or
  `popDuration` (`:240-247`). Fix: write only the changed key, and clamp values to their UI ranges.
- **L6** Concurrent decodes of one meme append duplicate ids to `cacheOrder` (`MemeLibrary.swift:260-269`); the H6 rewrite fixes it.
- **L7** The code requirement accepts any Apple-anchored certificate with this team's OU, including Apple Development certificates (`Updater.swift:162`). `spctl` covers
  that today. To make it explicit, add `and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]` (Developer ID).
- **L8** `AppVersion.isNewer` maps `"1.0.3-beta"` to `1.0.0` (`MemeCamCore/Version.swift:11-12`). It is safe because prereleases are skipped, but a
  mistagged release silently never installs. Strip a `-suffix` before parsing, and test it.
- **L9** Accessibility: reaction changes are not announced. Post `AccessibilityNotification.Announcement` on a stable reaction change,
  rate-limited and only while VoiceOver is on. The live `ReactionChip` should carry `.updatesFrequently`. Twenty-four views use a fixed
  `.font(.system(size:))` or fixed frames, so check them with large text and the Accessibility Inspector.

## Verified OK

- App quit or crash: the extension gets `sinkDidStop` and shows the "paused" placeholder within 0.5 s (`DeviceSource.swift:100-106`, `:157-166`).
- Extension restart: the devices listener reconnects with backoff (`VirtualCameraSink.swift:111-117`, `:149-152`).
- Update verification is sound: the signature is pinned to the team and bundle id with strict, nested validation, the version must equal the tag, and `spctl` must pass. A truncated download fails the
  `hdiutil` checksum or the signature check. The work dir is in the per-user `$TMPDIR`, so there is no cross-user TOCTOU. A translocated or read-only location produces a clear `notWritable` error.
- No retain cycles found: every long-lived closure captures `[weak self]`, and every owning object lives as long as the app.

## Test gaps

SwiftPM can `@testable import` executable targets on macOS: add `MemeCamTests` → `MemeCam` (or a `MemeCamKit` library). Cover:
1. `MemeLibrary` with an injected temp directory: add, remove, reassign and restore; path-traversal entries rejected (M6); a
   corrupted `user.json`; cache byte-budget eviction and LRU-on-hit (H6).
2. `AnimatedImage`: frame-delay parsing (GIF, APNG, WebP, tiny delays), `frame(at:)` for negative or long times, and the frame cap.
3. The updater: swap-script argument passing with `'`, spaces and `$` in paths (H10); `plainNotes`; `verify` rejects an
   ad-hoc-signed fixture (`codesign -s -` in the test); tags `v1.0.10`, `1.0.3-beta` and `1.0` (L8).
4. Extract the presentation logic (quiet mode, `popDuration`, forced memes, reactions with no memes) from `MemePipeline.setReaction`
   into a pure struct in `MemeCamCore` and test it with an injected clock.
5. `VirtualCameraController.recompute` as a pure function `(sinkStatus, extensionInfo, installOutcome, hasExtension) -> State`.
6. A Compositor smoke test: every layout at presence 0, 0.5 and 1 renders 1280×720 BGRA, and the pool does not grow over 300 frames.
7. Camera preference persistence (H4): an unknown camera ID at launch must not overwrite the stored preference.

## Prioritised fix list

1. H1 data races (small; removes a crash class); document the confinement invariant on every `@unchecked Sendable`.
2. H10 + H11 updater script args and off-main verification (an update that silently fails to relaunch is the worst UX).
3. H9 sink disconnect when idle and extension backoff (a few lines; removes about 200 wake-ups/s).
4. H3 + H4 camera switch rollback and preference persistence.
5. H2 async `CameraCapture.start` on its queue (no UI hangs on camera switch).
6. H5 connect/disconnect/wake recovery (depends on 4 and 5).
7. H6 byte-budget LRU and frame cap for memes.
8. H7 Vision at 15 Hz with `inputFaceObservations`; measure with powermetrics before and after.
9. H8 idle mode (consumer detection + occlusion), then M3 `beginActivity` and M4 thermal and low-power tiers.
10. M2 sink client verification and M5 deferred extension replacement.
11. M6 library path validation and background import; M7 updater state cleanup; M1 single watchdog.
12. M8 localisation plumbing (Russian), then tests 1–7, then the Low items.
