# MemeCam UX backlog (research-driven, Oct 2026)

Scope: what comparable products do well or badly, and 12 concrete improvements for MemeCam
(SwiftUI/AppKit/Core Image/Vision, no new dependencies). Research is web-search based (standard
search, few primary sources read in full); items marked "(inference)" are my synthesis, not a quoted source.
Existing state per README/CHANGELOG v1.0.2: quiet mode, 19 reactions, vote-window stabilizer, meme editor,
virtual camera (CMIO ext), menu bar extra, ⌘-shortcuts, auto-update, English-only UI (no localization found).

## 1. Findings per product

**Apple macOS/iOS Reactions (Sonoma+).** Gesture in view, away from the face, held until the effect shows;
thumbs up = hearts/thumbs, two thumbs up = fireworks, peace = balloons, two peace = confetti. Needs Apple silicon.
Master switch is the Reactions toggle in the menu-bar Video effects (Control Center) while a camera app is live, and it
stays off until re-enabled. Effects are 3D overlays composited into the outgoing video. Privacy: green/orange menu
bar dots show camera/mic use per app; a camera extension is attributed to the host app. Complaint pattern: accidental
effects in meetings, and Zoom also reacts to Apple gestures, so double triggers. Takeaway: a visible, one-click kill
switch plus "hold to trigger" is the expected contract.
Sources: [Apple video effects](https://support.apple.com/105117), [Apple guide](https://support.apple.com/guide/mac-help/mchlff01c919/),
[9to5Mac](https://9to5mac.com/2024/02/13/camera-reactions-ios-macos/), [Brown IT: turn off](https://ithelp.brown.edu/kb/articles/turn-off-video-call-reactions-in-macos-sonoma),
[macOS privacy dots](https://macrumors.com/how-to/menu-bar-dot-explanation). HIG text on camera effects was not found via search.

**Zoom reactions / gesture recognition.** Raised palm triggers the Raise Hand reaction; setting
"Activate the following emojis based on hand gesture recognition" is a separate opt-in checkbox. Community threads are full of
"random reactions / accidental hand raise" on low-quality video; the fix is always "turn gestures off".
Takeaway: gestures need per-gesture opt-out and a global switch, not just sensitivity.
Source: [Zoom Community](https://community.zoom.com/t5/Meetings/Random-reactions/m-p/136470), [Raising Hand](https://community.zoom.com/t5/Meetings/Raising-Hand/td-p/60702).

**Google Meet reactions.** Manual emoji picker; reactions float as a badge/burst, are lightweight and non-disruptive, and
burst-aggregate when many arrive. Takeaway: manual trigger is the baseline; animation should be short and unobtrusive.
Source: [Workspace Updates](https://workspaceupdates.googleblog.com/2023/01/in-meeting-reactions-for-google-meet.html), [Android Central](https://androidcentral.com/apps-software/google-meet-emoji-reactions-360-backgrounds).

**Discord soundboard.** Loved: one-click, per-server and favourites. Complaints: no volume control for the sender,
no reporting/moderation of sounds. Takeaway: if MemeCam adds sound, give per-meme volume and a default of off.
Source: [Discord community](https://support.discord.com/hc/en-us/community/posts/15402182597399-Problems-and-general-ideas).

**Camo (Reincubate).** Praised for quality, many controls on the Mac, and no latency/crashes in a review, with processing
offloaded to the phone. Criticised for price (~$40/yr). Takeaway: controls panel (resolution/FPS/flip) is a selling point.
Sources: [Macworld](https://www.macworld.com/article/3568492/camo-review.html), [TidBITS](https://tidbits.com/2020/07/24/turn-your-iphone-into-a-powerful-webcam-with-camo/).

**Snap Camera (discontinued Jan 2023) and successors.** Shutdown left a vacuum for fun overlays; users migrated to
ManyCam, XSplit VCam, OBS. Demonstrates the risk of cloud-dependent/unmaintained virtual cameras; MemeCam being local is a plus.
Source: [Snap community thread](https://community.snap.com/snapar/discussion/comment/2596), [filtermaker.fr](https://filtermaker.fr/en/?p=28135).

**XSplit VCam / vcam.ai, Elgato Camera Hub, NVIDIA Broadcast.** Recurrent: device listed but black video in Zoom/FaceTime
on Apple silicon, no way to change camera settings, some apps do not see the device, resolution must be lowered to
webcam-class, NVIDIA Broadcast breaking in Zoom until reinstall.
Takeaway: "device exists but frames are black" is the top failure; need self-diagnosis and visible status.
Sources: [vcam.ai black Zoom](https://feedback.vcam.ai/bug-reports/p/vcamai-doesnt-render-any-video-in-zoomusapp-on-my-macbook-pro),
[vcam.ai no settings](https://feedback.vcam.ai/bug-reports/p/no-way-to-change-camera-settings),
[Zoom community: Broadcast](https://community.zoom.com/meetings-2/nvidia-broadcast-camera-is-not-working-properly-82126),
[Elgato/GoToMeeting](https://community.logmein.com/t5/GoToMeeting-Discussions/Elgato-Facecam-does-not-work-on-gotomeeting-but-works-on/m-p/288069/highlight/true).

**OBS virtual camera (macOS).** Since Camera Extensions, the extension is installed but must be manually enabled in System Settings >
Login Items & Extensions > Camera Extensions; users call it "weird and unintuitive"; blurry/pixelated output and black
frames in Zoom also reported. Takeaway: MemeCam's setup pill is right; guide the user through the exact Settings path with
live detection of the enabled state.
Source: [OBS forum Sequoia](https://obsproject.com/forum/threads/sequoia-15-0-and-obs.179883/), [OBS blurry](https://obsproject.com/forum/threads/obs-virtual-cam-output-is-blury-and-pixelish.118650/page-3).

**mmhmm/Airtime, Krisp.** Not researched in depth (no useful search hits); omitted rather than guessed.

**Cross-cutting themes.** (1) accidental triggers dominate complaints; (2) kill switch + hold-to-trigger is table stakes;
(3) virtual camera setup/black-frame failures; (4) resolution/aspect control; (5) cheap manual override alongside auto-detection.

## 2. Prioritised backlog (top 12)

Effort: S = ~1-3 h, M = ~half-day, L = 1+ day.

1. **Global "Reactions on/off" + panic hotkey** - S, risk low.
   Value: Apple/Zoom users' #1 need is an instant off. Build: a global hotkey (Carbon `RegisterEventHotKey`, no sandbox issue; default ⌃⌥⌘M)
   plus menu-bar toggle and a "paused" badge on preview. Paused = frames pass through camera-only (reuse quiet-mode path). Persist in UserDefaults.
2. **Hold-to-trigger dwell + per-reaction cooldown** - S, risk low (tuning).
   Value: cuts accidental pop-ups (Apple "hold the gesture"; Zoom complaints). Build: add per-reaction `minDwell` (hand gestures 400-600 ms, faces
   shorter) and `cooldown` (default 4 s, same reaction cannot re-fire) to `ReactionStabilizer`; expose one "Strictness" slider (Relaxed/Normal/Strict) mapping to both.
   Validate with the existing Accuracy Test (false switches metric).
3. **Per-reaction enable/disable toggles (and "gestures off, faces on")** - S, risk low.
   Value: Zoom's gesture checkbox is the most used fix. Build: switch per row in the reaction strip/editor plus two group toggles (Face / Hands);
   disabled reactions are masked from the stabilizer vote. Today you must delete memes to switch off - replace with a reversible toggle.
4. **Manual trigger palette (menu bar + floating Stream-Deck-style grid)** - M, risk low.
   Value: Meet-style manual reaction; deterministic when detection is wrong. Build: SwiftUI grid of meme thumbnails in the menu-bar popover and an optional
   `NSPanel` (non-activating, floating, ⌃⌥Space); click forces that reaction for N s with the same pop animation. Add ⌃⌥1...9 hotkeys for the first nine favourites.
5. **Sticker-style pop animation** - S/M, risk low.
   Value: Apple/Meet effects feel alive; a hard crossfade feels flat. Build: in `Compositor`, animate scale 0.6->1.08->1.0 (spring) with slight rotation
   and drop shadow/white sticker outline (CIMorphologyMaximum on alpha + CIColorMatrix), exit = scale-down + fade; time-based, no extra buffers.
   Setting: Style (Pop / Slide / Fade) and "Reduce motion" follows `accessibilityDisplayShouldReduceMotion`.
6. **Russian localization (ru + en) with String Catalog** - M, risk low.
   Value: audience is Russian-speaking; reaction names, onboarding, permission text. Build: `Localizable.xcstrings` (works with SwiftPM resources/
   `String(localized:)`), move literals, localise `NSCameraUsageDescription`, reaction labels, meme manifest names; add an in-app language override. Check plural forms in ru.
7. **Virtual camera health card + black-frame self-test** - M, risk medium.
   Value: top complaint category (black frame, device missing, stale device list). Build: status card in the pill popover with checks (extension enabled, sink connected,
   frames/s delivered, last consumer attached) and fix-it buttons (open Camera Extensions settings via URL, "restart Discord/Zoom" hint, copy `systemextensionsctl` output).
   Show a 1-px test pattern to the extension when idle so apps never show black.
8. **Low-power mode when nobody consumes the virtual camera** - M, risk medium.
   Value: battery/CPU is a standard complaint; M1 8 GB. Build: track consumer count via the CMIO extension (stream start/stop) and `NSWorkspace` camera use;
   when the preview window is hidden and no consumer is attached, stop Vision and drop capture to 5 fps or stop session; auto-resume on consumer attach. Also lower Vision rate
   to 15 fps on battery/Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`), and stop hand pose when no hand was seen for 2 s (detect hands every 3rd frame).
9. **Virtual-camera resolution and aspect options** - M, risk medium.
   Value: Camo's selling point; avoid blurry/pixelated complaints and Discord bitrate. Build: picker 540p/720p/1080p, 16:9 / 4:3 / square crop, optional mirror toggle
   (mirror preview only vs output). Compositor already uses an IOSurface pool; make size a parameter and re-announce the extension format. 1080p is upscaled from 720p capture, so offer capture preset 1080p only when selected.
10. **"Away" behaviour** - S, risk low.
   Value: leaving the desk should not leave a cat pop-up or freeze. Build: after N s of "nobody here" (setting 5-60 s), show a chosen "away" meme/card (or
   blurred camera + "Be right back") and pause detection to low rate; fade back on return. The "nobody here" reaction already exists, so this is a timer plus a sink mode.
11. **Optional sound effects per meme (default off)** - S/M, risk low (copyright of sounds).
   Value: meme comedy, Discord-soundboard appeal. Build: per-meme optional audio file in the editor, played via `AVAudioPlayer` locally with volume slider and global mute;
   note that it does not enter the call (virtual camera has no audio) - state this in UI, or later pair with a virtual mic (out of scope). Respect cooldown (item 2).
12. **Privacy and status clarity** - S, risk low.
   Value: users trust apps that show camera state (macOS dots only name the app). Build: menu-bar icon states (idle/live/paused/away), "Camera is on" chip in the main window, auto-stop
   capture on screen lock/sleep (`NSWorkspace` notifications), "Nothing leaves this Mac" line in onboarding, and a one-click "Stop camera" in the menu bar extra.

## 3. Onboarding friction (fold into items 6/7)

- Detect each step live (extension enabled, camera permission) and tick it automatically; deep-link to *System Settings > Login Items & Extensions > Camera Extensions*.
- Offer "Try without virtual camera" first so the fun part is reached in under 30 s; virtual camera setup becomes step 2 (OBS friction suggests users abandon here).
- Post-approval hint: "Restart Discord/Telegram/Zoom" with a one-click per-app quit/relaunch for running known apps (needs confirmation prompt).

## 4. Suggested order

Week 1: 1, 2, 3, 12 (control and trust). Week 2: 5, 4, 10 (delight). Week 3: 6, 7 (reach and reliability). Week 4: 8, 9, 11.

## 5. Caveats

- Search was US-only standard mode; Reddit and App Store review text was not directly retrievable, so complaint claims lean on vendor forums/support posts.
- Apple HIG guidance on camera effects was not found; privacy-dot behaviour is from secondary sources. Verify before citing in marketing.
- No performance numbers were measured; effort estimates assume familiarity with the codebase (`MemePipeline`, `Compositor`, `ReactionStabilizer`).
