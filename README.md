# MemeCam

Native macOS app that watches your face and hands and shows a matching cat/hamster meme next to your camera.
The composited 1280×720 output can be used as a virtual camera called **MemeCam** in Discord, Telegram and others.

```sh
swift build && swift run MemeCam     # dev run (no virtual camera)
scripts/build-app.sh                 # build/MemeCam.app
```

## Virtual camera

The virtual camera is a CoreMediaIO camera extension (`CameraExtension/`) embedded in the app. macOS only loads it
when it is signed with a provisioning profile that grants the System Extension capability (paid Apple Developer account).

1. **Provision signing** (once): `uv run --script scripts/setup-signing.py`
   Creates `~/.memecam-signing/{signing.env, MemeCam.provisionprofile, CameraExtension.provisionprofile}`.
   Without these, `build-app.sh` still compiles the extension but ships an ad-hoc signed app without it.
2. **Build and install**: `scripts/build-app.sh --install --run`
   The app must run from `/Applications`, otherwise macOS refuses to install the extension.
   Every build gets a new `CFBundleVersion`, so a newer extension replaces the old one.
3. **Install the camera**: click *Install Virtual Camera* in MemeCam.
4. **Approve it**: System Settings > General > Login Items & Extensions > Camera Extensions, enable *MemeCam*
   (admin password). MemeCam re-checks automatically when you switch back to it.
5. **Use it**: in Discord (Settings > Voice & Video > Camera) or Telegram (Settings > Calls > Camera) pick **MemeCam**.
   When MemeCam's camera is stopped or the app is closed, the virtual camera shows a "MemeCam is paused" frame.

### Troubleshooting

- Camera not listed: quit and restart Discord/Telegram after approving (they cache the device list).
- Check the extension state: `systemextensionsctl list` (look for `com.hexarch.memecam.camera-extension`, `[activated enabled]`).
- Logs: `log stream --predicate 'subsystem == "com.apple.cmio"'`; MemeCam's own:
  `log stream --predicate 'subsystem BEGINSWITH "com.hexarch.memecam"'`.
- "Must run from /Applications" / signature errors: re-run `scripts/build-app.sh --install` and open `/Applications/MemeCam.app`.
- Signing check: `codesign -dvv --entitlements - /Applications/MemeCam.app`.
