# Changelog

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
