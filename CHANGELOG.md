# Changelog

## v1.2.2 — 2026-10-07

- Fix: on a Mac where the camera extension had just been installed and approved, the *MemeCam* camera could
  stay invisible to the app (“Connecting…”, “Open System Settings” although everything was on) until MemeCam
  was restarted — macOS doesn't hand a newly installed camera to the process that installed it. MemeCam now
  relaunches itself once when the extension is on but its camera stays missing for 5 s, and otherwise the
  health check offers *Restart MemeCam*.

## v1.2.1 — 2026-10-07

- Fix: the menu bar popover was cut off on the left in Russian — the layout picker's long titles made the
  content wider than the popover. The picker now shows icons (titles in the tooltip and for VoiceOver) next to
  a *Layout* label, the stop button reads *Turn Off*, and the pause hint wraps instead of being truncated.
- Smoother scrolling in Settings, the meme library and the toolbar: they no longer re-render with every
  10 Hz detection update (only the live reaction chip and the diagnostics rows follow it).

## v1.2.0 — 2026-10-07

- **Smarter recognition out of the box** — two learned face models now vote with the landmark rules:
  MediaPipe Face Mesh V2 + Blendshapes V2 (52 expression coefficients) and HSEmotion (8 expressions). Each
  expression component (mouth open, smile, eyes closed, brows, sad) is a weighted mean of the sources that saw
  the frame; a confidently neutral face damps everything, so resting and talking trigger less. Sad faces that
  the landmarks missed are now caught. ~1.8 ms per frame on the Neural Engine; without the models (still
  loading) recognition works as before.
- **Teach MemeCam your face** (⌘T, *Teach* in the control bar, a reaction's context menu, or Settings ›
  *Your Face*) — show each reaction twice, a bit differently each time (~4 min). MemeCam learns your way of
  doing them and uses it only where it really recognises you better (checked on a take it didn't learn from);
  re-teach single reactions any time, or forget everything. Only face and hand points are kept, on this Mac.
- **Virtual camera output format** — Settings › *Virtual Camera Output*: 720p or 1080p, 16:9, 4:3 or 1:1. Apps
  see all six formats; one that asks for another size gets the picture cropped to fit.
- Fix: after an update replaced the camera extension, the MemeCam camera vanished from the app until it was
  relaunched; MemeCam now relaunches itself and restores the camera. The update no longer waits for MemeCam's
  own feed, only for other apps using the camera.
- Readability: button titles on the orange accent and secondary text have more contrast.
- Menu bar: a paw icon, outlined when the camera is off and filled when it's live.

## v1.1.1 — 2026-10-07

- Fix: Inspector › *Language* › *Restart* no longer opens a second MemeCam while the first is still quitting;
  a detached helper waits for the old process to exit, then opens the app again (gives up after 30 s if the quit
  was cancelled).
- Fix: in quiet mode, after a triggered meme hides, the reaction chip shows what is detected now instead of
  the triggered reaction.
- Russian onboarding: the “How do you want to start?” cards no longer hyphenate words mid-line, and their
  footnotes fit on one line; the test-pattern description in the virtual-camera popover is no longer cut off.
- Meme import: files over 50 MB or 100 megapixels are refused with a clear message; a failed save no longer
  leaves an orphaned copy or a phantom entry; non-file drops are ignored.
- Accessibility: trigger tiles say whether they fire a random or pinned meme, their hotkey, and why nothing
  happens while paused or with the camera off; each health-check row reads its status (OK / Needs attention /
  Failed / Checking) with its fix button right after it; the pause button reports its state; the trigger
  palette's header reads without key symbols.
- Dev: `MEMECAM_RENDER_UI=<dir> swift run MemeCam -AppleLanguages '(ru)'` (debug builds) renders every
  onboarding step, the virtual-camera popover and the “Be right back” card to PNGs.

## v1.1.0 — 2026-10-07

- **Virtual camera health check** — the virtual-camera pill popover is now a live checklist: extension
  installed & enabled, “MemeCam” camera visible to apps, frames flowing (fps), apps using the camera right now
  (from the extension's client count), each with a one-click fix (*Install* / *Open System Settings* /
  *Start Camera*). *Send test pattern* feeds an animated test card (colour bars, “MemeCam test”, a running clock)
  to the virtual camera, so you can check that Discord or Telegram see MemeCam without turning the camera on;
  starting the camera switches it off.
- **Be right back** — after “Nobody here” has been on for a while (inspector › Picture › *Away after*:
  Off / 10 s / 30 s / 1 min, default 30 s) the call sees a blurred camera with a “Be right back” card that pops
  in like a sticker, until your face is back. Detection drops to 4 Hz meanwhile; an “Away” badge shows on the stage.
  Not while memes are paused.
- **Privacy clarity** — the menu bar icon shows the camera state (off / on / memes paused / away); while the camera
  runs, *Stop Camera* is always the first item of the menu bar window; “Video is processed on this Mac only —
  nothing is uploaded” in the first onboarding step and the inspector's Updates section.
- **Russian meme titles** — `memes.json` takes an optional `title_ru`, used when MemeCam runs in Russian (captions,
  meme editor); all bundled memes have one. The extension's “MemeCam is paused” frame is in Russian when the
  system language is Russian.
- **Russian localization** — the whole UI (onboarding, inspector, menus, menu bar extra, accuracy test,
  updater and camera/virtual-camera errors, reaction names and instructions, camera permission prompts)
  follows the system language. Inspector › *Language* overrides it for MemeCam only (System / English /
  Русский) with a *Restart* button. Strings live in `Resources/Localization/{en,ru}.lproj`;
  `scripts/check-strings.sh` verifies the tables against the keys the compiler extracts from the code.
- **Trigger palette** — nine manual trigger slots (default: smile, laugh, surprised, thumbs up/down, heart,
  facepalm, thinking, hands up). Global hotkeys **⌃⌥1 … ⌃⌥9** fire them while Discord/Zoom stays frontmost
  (switch off in inspector › Triggers); a 3×3 grid in the menu bar extra; a small floating Liquid Glass palette
  (**⌃⌥0**, *Window › Show Trigger Palette*) that never takes focus from the call, is draggable and remembers
  its position. Right-click a tile → *Assign Reaction* or *Assign Meme* (one specific meme or random).
  Triggered memes pop up with the chosen animation and hide after *Meme stays*; nothing fires while paused.
- Fix: a pop-up whose meme wasn't decoded yet briefly showed the previously hidden meme; forced
  “Neutral”/“Nobody here” memes now pop up and hide like the others in quiet mode.
- **Sticker-style pop-ups** — in quiet mode the camera now stays full-frame and the meme floats over it as a
  card: *Pop* (default) springs in like a sticker with a white outline and soft shadow, *Slide* glides in from
  the nearest edge, *Fade* keeps the old crossfade. Pick it in inspector › Picture › *Pop-up style*;
  with macOS *Reduce motion* on, memes always fade.
- **Pause memes** — one switch for a plain camera (detection keeps running, nothing pops up):
  global hotkey **⌃⌥P** that works while Discord/Zoom is frontmost (no Accessibility permission),
  toggle at the top of the menu bar extra, in the control bar and *Camera › Pause Memes*.
  “Paused” badge on the stage and a pause icon in the menu bar.
- **Per-reaction on/off** — a switch in the meme editor and *Turn Off / Turn On* in the reaction strip
  and gallery context menus. Off reactions are still detected but never pop up; their cards are dimmed with an “Off” badge.
- **Cooldown** — the same reaction can't pop up again for a few seconds after its meme went away
  (default 4 s, 0–10 s in inspector › Picture). Neutral and “nobody here” are exempt.
- **Idle mode** — with the MemeCam window closed, minimised or covered and no app using the MemeCam
  camera, detection, compositing and the virtual-camera feed pause (the menu bar shows “Idle — saving power”);
  they resume as soon as the window shows or Discord/Zoom opens the camera. The camera extension now reports
  how many apps read it, so a call with the window closed keeps full speed.
- **Lighter detection** — Vision is capped at 15 Hz (was ~30), 10 Hz in Low Power Mode and 8 Hz when the
  Mac is hot; the face is detected once and fed to the landmarks request. The hidden preview gets no frames.
- **Camera recovery** — unplugged or out-of-range cameras fall back to the default and switch back when
  they return; session errors restart the camera with backoff; the camera pauses during sleep and resumes on wake.
  New setting *Stop camera when Mac locks* (on by default; resumes on unlock).
- **Camera choice is remembered** even when that camera is missing at launch (“iPhone (not connected)” in the menu).
- Fix: switching cameras no longer freezes the window (configuration runs off the main thread), a failed
  switch keeps the current camera running and says why, and repeated starts no longer pile up watchdog timers.
- Fix: data races between the UI, capture and Vision threads (camera name, running flag, hand-detection flag,
  frame timing) that could crash while switching cameras.

## v1.0.2 — 2026-10-07

- **Auto-update from GitHub Releases**: checks on launch and every 6 h, verifies the download against
  MemeCam's Team ID and Apple notarization, swaps itself in place and relaunches (also updates the camera extension).
  *Menu › Check for Updates…*, toggle in the inspector.
- **Quiet mode** (default): nothing on screen while you look neutral — memes pop up on a confident
  reaction and hide after a few seconds (2–10 s, inspector › Picture). Smooth crossfade to full-frame camera.
- **Calmer reactions**: only confident frames vote, a clear majority is needed to switch, memes stay ≥1.5 s.
- **Remove all memes of a reaction to switch it off** — it is no longer replaced by a similar reaction.
- Detection tuned on a real guided recording (macro-F1 0.67 → 0.86, 0 false switches):
  surprise uses raised brows + dropped jaw (FACS), eyes-closed threshold matches Vision's eye contour,
  facepalm/thinking geometry, hands briefly held when Vision loses them over the face,
  wrist estimation for peace signs, the learned model is skipped for guessed wrists.

## v1.0.1 — 2026-10-07

- Fix: MemeCam did not launch on other Macs — the app declared an App Group its Developer ID profile
  did not grant. The app no longer needs one; the camera extension's profile now authorizes it.
- The app itself is notarized and stapled (not only the DMG), so it verifies offline after copying.
- Build guard: every entitlement is checked against its provisioning profile; `syspolicy_check` runs on releases.
- Virtual camera shows **Ready · Start Camera** when installed but idle (was “Connecting…”).
- New Liquid Glass app icon.

## v1.0.0 — 2026-10-07

First release.

- Real-time face expressions (8) and hand gestures (10) → matching cat/hamster meme; 41 bundled memes.
- Learned hand-gesture MLP trained on HaGRID v2 (macro-F1 0.987), pure-Swift inference with rule fallback.
- Personal neutral-face calibration, head-pose correction, One Euro smoothing, vote-window stabilizer.
- CoreMediaIO virtual camera “MemeCam” for Discord, Telegram, Zoom, browsers.
- Liquid Glass UI, onboarding, meme editor with drag & drop, menu bar extra, shortcuts.
- Interactive accuracy test with per-reaction F1 report.
- Developer ID signed and notarized DMG.
