# MemeCam - prior art research

Date: 2026-10. Method: `gh search repos`, shallow clones and reading of source. Star counts are from GitHub at research time.
Note: the space is a swarm of tiny hobby repos (0-15 stars). There is no mature project; no native macOS one exists.

## 1. Similar projects

| # | Repo | Stars | Stack |
|---|------|-------|-------|
| 1 | https://github.com/mertinkos/cat-face | 0 | Python, MediaPipe Face/Hand Landmarker, rule-based, cat memes |
| 2 | https://github.com/2-BrainCells/funny-hamster-meme | 0 | Python, MediaPipe Face+Hand Landmarker (tasks API), OpenCV, hamster memes |
| 3 | https://github.com/haidangve/Hamster-Matching | 2 | TypeScript/React, MediaPipe tasks-vision in browser (blendshapes + transform matrix), hamster memes |
| 4 | https://github.com/TejasLamba2006/gestura | 1 | Python, MediaPipe Hand+Face+Pose, hamster memes, vote-window smoothing |
| 5 | https://github.com/K4ZED/MonkeyMeme-Gesture_Tracker | 15 | Python, legacy mp.solutions Hands + FaceMesh, monkey memes (most starred) |
| 6 | https://github.com/kelfinofarelino/monkey-meme-gesture-cam | 2 | Python, MediaPipe, tiny (111 lines) |
| 7 | https://github.com/addas97/Real-time-Meme-Expression-Classifier | 0 | Python, MediaPipe landmarks -> engineered features -> scikit-learn / PyTorch MLP, trained on user-collected data |
| 8 | https://github.com/pedrol2b/virtual-camera | 3 | Swift/SwiftUI, AVFoundation + Vision (VNDetectHumanHandPoseRequest), NDI + OBS output; only native one, but not a meme matcher |

Others seen (not read): ShahdMahmoud9/meme-gesture-detector, mrcLrnzZ/Monkey-Gestures, logic1391/meme-mirror, wwwillgunnn/hamster-match, haidangve and TejasLamba2006 clones.

### Per-repo notes (what is detected, how, mapping, problems)

**cat-face (rules).** Sleepy = EAR < 0.18 AND MAR > 0.45. Sad = blendshapes mouthPucker/mouthFunnel > 0.45 with smile < 0.30; geometric fallback: mouth width < 0.42 * inter-ocular distance. Hands: finger extended if dist(tip, wrist) > 1.15 * dist(pip, wrist); thumb extended if tip further from wrist than IP and dist(tip, indexMCP) > 0.5 * hand size; shaka = thumb+pinky only; pointing = index only; praying = two wrists within 1.2*hand size, middle tips within 0.8*, tips above wrists; "cool" (hand by temple) = fingertip lateral offset > 0.55 face scale, above eye line + 0.5, near head-side landmarks < 0.55. Mapping: priority-ordered if/else returning a string key -> image. Smoothing: `PoseStabilizer`: hold 0.5 s to confirm, 0.3 s grace after loss. Good clean architecture: face_rules / hand_rules / matcher.

**funny-hamster-meme (nearest-neighbour).** Computes a 13-dim feature vector per frame (surprise, smile, concern, cheers, hand_raised, num_hands, EAR, eye symmetry, MAR, mouth width ratio, mouth elevation, brow height, brow symmetry) and the same vector for each meme (hand-authored in `expression_templates.json` since hamster faces cannot be landmarked). Weighted similarity (weights 10-30, falloffs 5-15) picks the best meme. Anti-flicker: EMA 0.3 over the whole feature dict, challenger must beat incumbent by 5% (`switch_margin 1.05`), 15-frame face-loss grace, process every 2nd frame (`frame_skip=2`). Very good idea: a startup self-check that every meme is reachable (wins on its own template) - catches duplicate vectors. Features: EAR = mean(upper-lower landmark distance)/eye width; MAR = dist(13,14)/dist(61,291); brow height = eye centre y - brow mean y; mouth elevation = nose tip y - mouth-corner mean y; hand_raised if middle fingertip y < face centre + 0.2 or wrist y < face top + 0.3. Perf: runs both IMAGE and VIDEO landmarkers (4 models loaded), pickles meme features.

**Hamster-Matching (blendshapes + scoring).** Uses MediaPipe blendshapes: mouthOpen = jawOpen; smile = mean(mouthSmileL/R); asymmetry = |smileL - smileR|; eyeOpen = 1 - clamp(0.8*blink + 0.35*squint); browDown = mean(browDownL/R); mouthPucker; tongueOut; yaw/tilt from the 4x4 facial transformation matrix (m02, m10) or fallback from landmarks 33/263/1/234/454. Meme chosen first by hard hand rules (hands close -> love; index up AND near mouth -> shush; thumb up -> like), then weighted additive scores per meme with bonus triggers: smirk if asym > 0.14 && smile > 0.16; angry if browDown > 0.35 && smile < 0.2; eyeclosed if eyeOpen < 0.22; pout if pucker > 0.35 && smile < 0.25; tongue if jawOpen > 0.28 && smile > 0.35. Hand rules (y-only, image coordinates): finger extended = tip.y < pip.y < mcp.y; thumb up = thumb tip above IP and middle/ring/pinky curled (weak: no rotation handling). Near-mouth: index tip within 0.12 (normalised image units) of lip midpoint; near head: wrist < 0.22 from (forehead+nose).

**gestura (best hand logic).** Hard-won comments:
- Thumb extension = dist(thumbTip, pinkyMCP) > 1.1 * dist(thumbMCP(2), pinkyMCP) - rotation-invariant, because "distance to palm centre" breaks on thumbs-up.
- Evaluate the four fingers first; all four curled -> thumbs_up if thumb extended else fist (thumb-first misclassified sideways fists).
- Thumbs-down = (thumbTip.y - wrist.y) / dist(wrist, middleMCP) > 0.35 (0.25 flickered).
- Pinch: dist(thumb, index) < 0.5 * hand size AND dist(thumb,index) < 0.7 * dist(thumb,middle) (separates from fist).
- Fist/thumb near head beside face = "lollipop": |handY - 0.3| < 0.15, 0.08 < |handX - 0.5| < 0.30. Hand-shape checks before positional ones.
- Bicep flex: elbow angle < threshold with wrist above elbow by > 0.06 (pose model). Crossed arms: wrists < 0.18 apart in the chest band. Glasses pinch near face < 0.28, finger-at-mouth < 0.14.
- Head yaw = asin(R[0][2]) in degrees from transformation matrix. Temporal: majority vote over a window (VOTE_WINDOW) -> stable gesture. Runs Hand+Face+Pose each frame: heavy.

**MonkeyMeme-Gesture_Tracker.** Legacy `mp.solutions`; "thinking" = index tip within a pixel threshold (50 px mouth, fixed - breaks with distance from camera) of mouth and middle finger down; nose-distance variant. Lesson: use normalised-by-face-size distances, not pixels.

**Real-time-Meme-Expression-Classifier.** 400-line feature extractor (landmark distances/angles normalised by face size) -> small MLP/sklearn trained on webcam samples recorded by the user (`data_collector.py`, `train.py`). Good for personalisation; costs a data-collection UX.

**pedrol2b/virtual-camera (Swift).** Calls hand pose + face rectangles + body pose in ONE `VNImageRequestHandler.perform([...])` per frame, `maximumHandCount = 2`. Straight pattern for us (but see perf notes: it creates a handler per frame and runs everything every frame).

### Common problems reported/visible across these repos
1. Flicker between memes -> everyone ends up with EMA, hold timers, voting windows, switch margins.
2. Thumb detection is rotation-dependent; y-only rules fail when hand tilts.
3. Pixel thresholds break with distance; normalise by face/hand size.
4. Python/OpenCV loop at ~15-25 FPS on laptops, CPU only; running Hand+Face+Pose each frame; Face Mesh 468 pts is overkill for ~6 expressions.
5. Animal meme images cannot be landmarked -> expression templates must be hand-authored.
6. Multi-face / hand-occlusion of face kills face landmarks exactly when "hand over mouth" gestures need them.
7. No project produces a virtual camera output with matched memes; all show a separate OpenCV window.

## 2. Geometric heuristics (reusable, with thresholds)

All distances normalised: face scale F = inter-ocular distance (outer eye corners); hand scale H = |wrist - middleMCP|. Image y grows downward (Vision uses origin bottom-left - flip!).

### Face (MediaPipe indices given; Vision equivalents in section 3)
| Signal | Formula | Threshold |
|---|---|---|
| EAR (eye aspect) | (|p2-p6| + |p3-p5|) / (2*|p1-p4|), idx L [33,160,158,133,153,144] R [362,385,387,263,373,380] | open ~0.28-0.35; closed/blink < 0.18-0.21; squint 0.18-0.24; sleepy: EAR < 0.18 and MAR > 0.45 |
| MAR (mouth open) | |13-14| / |61-291| | closed < 0.05; talking 0.1-0.3; open/shocked > 0.35-0.5; yawn > 0.6. Blendshape equivalent jawOpen > 0.28 mouth open, > 0.5 scream |
| Smile | corner lift: noseTip.y - mean(corner.y) rising, or mouth width / F; blendshape mean smileL/R | blendshape smile > 0.35 clear, 0.16-0.35 slight |
| Smirk | |smileL - smileR| | > 0.14 with smile > 0.16 |
| Pucker/pout | inner mouth width / outer width falls, mouth width < 0.42 F | blendshape pucker > 0.35-0.45 with smile < 0.25-0.30 |
| Brow raise | (eyeCentre.y - browMean.y) / F; relative to user baseline | +25-30 % over calibrated neutral = raised (surprise) |
| Brow down (angry) | same ratio decreases | < -15-20 % of baseline, or blendshape browDown > 0.35 with smile < 0.2 |
| Eyes closed | EAR | < 0.22 held for > 300 ms (not a blink; blinks last 100-200 ms) |
| Head tilt (roll) | atan2(rightEye.y-leftEye.y, rightEye.x-leftEye.x) | |roll| > 12-15 deg = tilt |
| Head yaw | asin(R02) or (nose.x - cheekMid.x)/halfWidth | |yaw| > 20 deg = turned ("smug"); normalised > 0.35 |
| Tongue out | no landmark rule; blendshape tongueOut only | N/A in Vision; infer: MAR 0.25-0.5 + smile (Hamster-Matching heuristic) |

Key insight from the repos: absolute thresholds vary per person/camera -> add a 2 s neutral-face calibration (store baseline EAR, MAR, brow ratio) and use ratios to baseline.

### Hand (21 joints; indices wrist 0, thumb 1-4, index 5-8, middle 9-12, ring 13-16, pinky 17-20)
- Finger extended (rotation-invariant): dist(tip, wrist) > 1.15 * dist(PIP, wrist). Better still: angle at PIP between (MCP-PIP) and (TIP-PIP) > 160 deg.
- Thumb extended: dist(thumbTip, pinkyMCP) > 1.1 * dist(thumbMCP, pinkyMCP) (gestura) or dist(thumbTip, indexMCP) > 0.5 H.
- **Thumbs up** = four fingers curled (tip nearer wrist than PIP*1.15) AND thumb extended AND thumb direction vertical: (wrist.y - thumbTip.y)/H (y down) > 0.35 up; thumbs down when < -0.35 (hysteresis: enter 0.35, exit 0.25).
- Fist: all five curled. Open palm: all five extended. Pointing: index only. Peace: index+middle. Shaka: thumb+pinky only. OK: thumb-index pinch dist < 0.5 H and others extended. Pinch: thumbIdx < 0.5H and < 0.7*thumbMiddle.
- Shush: index extended only AND index tip within 0.12 (image) or ~0.5-0.7 F of lip midpoint.
- Hand over mouth: min(dist(palm centre or tips, mouth)) < 0.7 F.
- Praying/clap: wrists within 1.2 H, middle tips within 0.8 H, tips above wrists.
- Heart/love: two hands, palm/index/thumb distance (/avg hand scale) < 1.9 / 1.5 / 1.5.
- Hand raised: wrist.y above face-top + 0.3 or middle tip above face centre + 0.2.
- Temple "cool/agent": tip lateral offset > 0.55 F from face centre, y above eye + 0.5 F, within 0.55 F of head-side points.

### Smoothing / selection patterns to copy
- EMA alpha 0.3 on continuous features (not on the discrete label).
- Hold-to-confirm 0.4-0.5 s for a new meme; 0.3 s release grace (cat-face PoseStabilizer) - or a vote window of ~7-9 frames (gestura).
- Hysteresis: challenger must beat incumbent by 5 % (funny-hamster).
- Face-loss grace ~15 frames (0.5 s) before dropping to default.
- Priority order: two-hand gestures > hand-near-face > hand shapes > face expressions > neutral default.
- Startup self-test that every meme is reachable and no two templates collide.
- Debug overlay (live feature values) - gestura/funny-hamster both rely on it for tuning.

## 3. Native Apple Vision vs their approach

| Aspect | Their approach (MediaPipe Python/JS) | Native Vision on M1 |
|---|---|---|
| Runtime | Python+OpenCV, GIL, BGR->RGB copies, 15-25 FPS typical | Swift, zero-copy CVPixelBuffer from AVCaptureVideoDataOutput, ANE/GPU-accelerated; 30-60 FPS feasible at 640x480 |
| Memory | MediaPipe + Python + OpenCV ~600 MB-1 GB | Vision framework models are shared system models: tens of MB in-app. Matters on 8 GB |
| Face | 478 landmarks + 52 blendshapes + transform matrix | `VNDetectFaceLandmarksRequest` (revision 3): 76 pts in regions: leftEye, rightEye, leftEyebrow, rightEyebrow, innerLips, outerLips, nose, noseCrest, medianLine, faceContour, leftPupil, rightPupil. Plus `roll`, `yaw`, `pitch` on VNFaceObservation for free (no matrix maths) |
| Blendshapes | jawOpen, smile, browDown, tongueOut... | NOT available (ARKit blendshapes need TrueDepth/ARFaceTracking, not a Mac webcam). Compute from geometry: MAR via innerLips top/bottom vs width, EAR from eye contour (8 pts: use max-y minus min-y over width), brow = eyebrow region mean y vs eye region y, smile = corner-y relative to lip centre / mouth width. No tongue -> use "open mouth + smile" heuristic or drop it |
| Hands | 21 landmarks, 2 hands | `VNDetectHumanHandPoseRequest`, same 21-joint model (wrist, thumbCMC/MP/IP/Tip, index MCP/PIP/DIP/Tip, ...), `maximumHandCount = 2`, per-joint confidence; reuse all hand rules above (map to `VNHumanHandPoseObservation.JointName`; filter confidence > 0.3-0.5). Thumb/palm ranges are as accurate as MediaPipe for frontal use, slightly worse for occlusion |
| Quality gate | none | `VNDetectFaceCaptureQualityRequest`: faceCaptureQuality 0-1; use as gating (ignore expression update when quality < ~0.25-0.3, e.g. strong blur, profile) instead of the "face-loss grace" hack. Not an expression detector |
| Body | Pose model for bicep/crossed arms | `VNDetectHumanBodyPoseRequest` - only add if needed; costs frames |
| Models to ship | downloads .task files at runtime | Built in, nothing to download or sign |

### Concrete optimisations vs the prior art
1. One `VNImageRequestHandler` per frame with face landmarks + hand pose requests together; set `usesCPUOnly = false` (default) so ANE/GPU is used. Do not create/destroy request objects per frame; keep them as properties and reuse.
2. Dedicated serial `DispatchQueue(qos: .userInitiated)` for Vision; `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames = true` so a slow frame never queues (the Python projects block the capture loop).
3. Capture at 640x480 or 1280x720 (`.vga640x480`/`.hd1280x720` preset); Vision internally scales, higher resolution only costs bandwidth. Use 30 FPS.
4. Stagger work: face every frame (expressions change fast), hand pose every 2nd frame when no hand was seen for N frames (cheap probe), every frame when hands present; skip hand pass entirely if face not visible for 2 s and user disabled gestures. funny-hamster gets only `frame_skip=2` on everything.
5. Hand prefilter: if `faceObservation.boundingBox` is large, crop the ROI for face landmarks via `regionOfInterest` (normalised rect) to cut compute; hand request ROI = last hand bbox expanded 1.5x (fallback to full frame every 10th frame).
6. Face tracking: `VNTrackObjectRequest` via `VNSequenceRequestHandler` can follow the face bbox between full detections (detect every 5-10 frames, track in between); then landmarks only on the tracked ROI.
7. Pre-compute meme templates once and cache (asset catalog `CGImage`s decoded at launch to `CVPixelBuffer`/`MTLTexture`); funny-hamster's pickle trick -> Codable JSON.
8. Rendering path stays on the GPU: compose meme over camera with Core Image (`CIContext(mtlDevice:)`) / Metal, output `CVPixelBuffer` from a pool (`CVPixelBufferPool`) to the virtual-camera sink; no CPU pixel copies. Python repos paste with NumPy on CPU.
9. Smoothing in Swift on a small `struct Features` using SIMD; run classification on the Vision queue, publish only label changes to SwiftUI (`@Observable`, hop to MainActor on change only), not 30 Hz view updates.
10. Calibration: 2 s neutral capture to personalise EAR/MAR/brow baselines. Persist in UserDefaults.
11. Use ML only if rules disappoint: Create ML hand-pose classifier (`MLHandPoseClassifier`) consuming `VNHumanHandPoseObservation.keypointsMultiArray()` is trainable from few samples and runs on ANE; Create ML also has action classification. Keep rules as v1 (zero data, debuggable).
12. Mind coordinates: Vision normalised points have origin bottom-left; face landmark points are relative to face bbox (use `landmark.pointsInImage(imageSize:)`). Mirror the preview but not the logic. Left/right eye are mirrored in selfie view.

Estimated budget on M1 (to verify by profiling with Instruments/Core ML + Vision template): face landmarks ~4-8 ms, hand pose ~3-6 ms per 640x480 frame, i.e. 30 FPS with headroom, versus 40-70 ms/frame for the Python stacks.

## 4. Virtual camera on macOS (CMIO Camera Extension)

Legacy DAL plugins are dead on macOS 13+/Sonoma+ for new apps; the supported route is a **Camera Extension** (CoreMediaIO `CMIOExtension*` API, macOS 12.3+; system extension shipped inside the app bundle, activated via `OSSystemExtensionRequest`). Requires a paid Apple Developer ID, `com.apple.developer.system-extension.install` entitlement, app group for sharing frames, and (for dev) System Settings approval; works in Zoom/Discord/Telegram/Meet in browsers, though some apps (hardened runtime without `disable-library-validation`) reject third-party cameras.

Two architectures: (a) extension owns capture + effect (simple but extension sandbox/CPU limits), (b) **app renders, extension is a thin relay**: app pushes frames into the extension's *sink stream* (CMIO sink via `CMIODeviceStartStream` + `CMSimpleQueue`), extension forwards to its *source stream*. (b) is what we want: Vision + rendering live in the app, extension stays tiny.

Repos to learn from:
- https://github.com/ldenoue/cameraextension (89 stars, 2022, Swift) - minimal sample derived from Apple's CMIOExtension template; source + sink streams, app->extension frame feed. Best starting skeleton. Fork https://github.com/csuft/cameraextension.
- https://github.com/whyisjake/Celluloid (38) - modern macOS, physical webcam -> Core Image/Metal filters/LUTs -> CMIO sink stream. Closest to our pipeline.
- https://github.com/adrbn/liveloop (50) - Swift virtual camera that loops buffered video; good for frame buffering/fallback frame handling.
- https://github.com/daily-co/daily-virtual-camera (58) - Swift virtual camera from Daily; production-style app-to-extension handoff.
- https://github.com/pedrol2b/virtual-camera (3) - SwiftUI + Vision hand gestures + NDI; relevant for Vision usage and app structure.
- https://github.com/MarkBesseyAT/CameraTest (1) - minimal install/uninstall of the system extension (activation flow only).
- https://github.com/obsproject/obs-studio (77k) - `plugins/mac-virtualcam` is the reference production implementation of a CMIO extension (+ older archived DAL plugin https://github.com/johnboiles/obs-mac-virtualcam, 4k). Read for activation UX, entitlements, IOSurface frame transport.
- Apple: "Creating a camera extension with Core Media I/O" (developer.apple.com doc) and WWDC22 session 10022 "Create camera extensions with Core Media IO".
- Apple dev forum threads of interest: "Virtual Camera Shows Jittering Frames and Solid Accent Color" (https://developer.apple.com/forums/thread/817478), "Camera extension is not reported as a video device" (thread 718128): common pitfalls (pixel format, timing, missing frames -> accent-colour fill).

Practical rules: output 1280x720 @30 `kCVPixelFormatType_32BGRA` (or 420v) with correct presentation timestamps; always keep sending frames (resend last frame at 30 Hz even if the meme did not change - otherwise Discord/Zoom shows the accent colour); use IOSurface-backed pixel buffers to avoid copies; mirror setting must be applied before output (users expect non-mirrored output to others); include a fallback "no face" image; Discord Electron may need the app to be started *after* the extension is enabled.

## 5. Recommendations for MemeCam

Reuse: rule-based detector in 3 layers (features -> signals -> priority-ordered matcher) like cat-face; feature smoothing + hysteresis + hold/grace from funny-hamster/cat-face; gestura's rotation-invariant thumb logic and thumbs-down threshold; template-based expression vectors for animal memes (hand-authored per meme in JSON, with reachability self-test); calibration; debug overlay.
Avoid: pixel-based distances, y-only finger tests, per-frame heavyweight models, tongue/blendshape dependence, label smoothing without hysteresis.
Differentiators nobody has: virtual camera output, native Vision speed/low RAM, calibration, user-editable meme packs.
