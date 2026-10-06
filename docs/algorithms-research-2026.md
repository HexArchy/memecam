# MemeCam - recognition algorithms research (2026)

Date: 2026-10. Scope: how to make face-expression and hand-gesture recognition more accurate, robust and
flicker-free on macOS 26 / M1 8 GB, compared with the current geometric pipeline
(`FaceMetrics` + `ReactionClassifier` + `HandShape` + `ReactionStabilizer` + `OneEuroFilter`, `VisionDetector`).
Builds on `docs/research.md` (the GitHub survey). Every number below carries a reference tag; `[O]` = I opened the
source, `[S]` = seen only in search-result snippets (treat as unverified). Anything without a tag is my own
engineering judgement and is labelled as such.

## 1. Executive summary

1. **Apple gives us nothing new for expressions.** There is no supported way to get ARKit's 52 blendshapes on a
   Mac: `ARFaceAnchor.blendShapes` is iOS/iPadOS only [O: A1]. WWDC25/26 added no expression, AU or blendshape
   request [O: A3, A4]. The one relevant change is that **macOS 26 replaced the hand-pose model** ("smaller,
   modernized ... improved accuracy, less memory usage, and less latency", 21 joints but "the joints are not in the
   same location as the previous model") **without a new revision constant** [O: A3, A5]. So our hand thresholds were
   tuned (or will be retuned) against a model that moved, and any classifier trained on MediaPipe or pre-26 Vision
   joints is out of distribution.
2. **For posed, exaggerated "meme" expressions, landmark geometry with a per-user neutral baseline is still a sound
   core.** Geometric methods reach 88.7-97.8 % on posed CK+ [S: P7] (93 % for a 2025 MediaPipe-landmark temporal
   model [O: P6]), while lightweight appearance CNNs reach only 62-66 % on in-the-wild AffectNet-7 [O: P3; S: P5].
   Also, the off-the-shelf FER label set (anger/disgust/fear/...) does not cover eyes-closed, brows-raised or head-tilt.
   The evidence is indirect (different datasets), so it has to be confirmed on our own clips (recommendation R1).
3. **The best learned upgrade for the face is MediaPipe Blendshapes V2, not an emotion CNN.** It is Apache-2.0, it is
   an MLP-Mixer that takes 146 FaceMesh landmarks and outputs 52 ARKit-named coefficients, it runs in 1.2 ms on a
   Pixel 6, and its model card shows no gender or skin-tone gap [O: P1, P2]. It **cannot** consume Vision's 76 points,
   though. You have to port FaceMesh V2 (256x256 crop, 8 ms on Pixel 6 GPU [O: P2]) too. That is a large job, so it
   is an optional phase-2 experiment.
4. **For hands, the biggest gain is a tiny learned classifier on Vision's own 21 keypoints**, trained on HaGRIDv2
   images re-landmarked with the macOS 26 Vision model, plus our own captures. HaGRIDv2 has every class we need
   (like, dislike, peace, palm, one/point, fist, hand_heart, no_gesture) [O: H1, H2]. Landmark MLPs reach about 98-99 %
   on clean static-gesture sets [S: H5; O: H6]. Keep the rules for the positional gestures (facepalm, thinking, hands
   up). There is a licence caveat; see R3.
5. **Cheap wins come first:** correct the metrics for yaw and pitch (today, yaw alone inflates every IOD-normalised
   vertical metric by up to 11 % inside the gate), make the face-detector revision and the 76-point constellation
   explicit, and build a replay/eval harness so that every threshold change can be measured.

## 2. Findings by topic

### 2.1 Apple platform (macOS 15 / 26, WWDC24-26)
- Swift-native Vision API (`DetectFaceLandmarksRequest`, `DetectHumanHandPoseRequest`, async `perform(on:)`)
  arrived in macOS 15. The hand request has only `revision1`, plus `maximumHandCount` [O: A2]. The face-landmarks
  doc page now also lists watchOS 27, but shows no new revision or option [O: A6].
- WWDC25 "Read documents using the Vision framework" also announced the replaced hand-pose model (quote above) and
  `DetectLensSmudgeRequest`, which returns a 0-1 confidence [O: A3]. A developer-forum thread confirms that no new revision
  symbol exists, so the model swap is silent and comes with the OS [O: A5].
- WWDC26 "What's new in image understanding": tap-to-segment, image input for Foundation Models, and Vision on
  watchOS. Nothing for faces or hands [O: A4]. (The on-device Foundation Model with image input would be far too slow
  for 30 FPS; at most it could tag meme images offline.)
- Face pose: since `VNDetectFaceRectanglesRequestRevision3` (WWDC21), roll, yaw and **pitch** are continuous. In
  revision 2, yaw "would always jump between 0 and ±0.785" [S: A8]. Landmarks revision 3 = 76-point constellation +
  pupils [O: A7]. `constellation` defaults to `constellationNotDefined` [O: A9], and our code does not set it.
- `DetectFaceCaptureQualityRequest` is "a comparative measure for the same subject", not across people [O: A7].
  It is fine as a per-user gate, but not as an absolute threshold.
- ARKit face tracking: iOS/iPadOS only [O: A1]. An unanswered Feb-2026 forum question asks exactly this [O: A10].
  **Answer: no supported path to blendshapes on Mac. Compute them yourself or port MediaPipe.**
- MediaPipe Tasks (Face Landmarker, Gesture Recognizer) is documented for iOS via CocoaPods. I found no documented
  macOS target [S: P8], so the realistic route is model conversion, not the SDK.

### 2.2 Learned face models usable via Core ML

| Option | What it outputs | Accuracy evidence | Size / speed | Licence | Fit for MemeCam |
|---|---|---|---|---|---|
| MediaPipe FaceMesh V2 + Blendshapes V2 | 478 landmarks + 52 blendshapes (browInnerUp, mouthFrown, eyeBlink, jawOpen, mouthSmile...) | landmark MNE 2.71 % of IOD vs 2.56 % human; blendshape MAD 0.199; gender/skin-tone delta ≤0.008 [O: P1, P2] | mesh 8 ms (Pixel 6 GPU), blendshapes 1.2 ms (Pixel 6 XNNPACK) [O: P2] | Apache-2.0 [O: P1] | Best semantic match (covers all 8 face classes) but needs a 2-model port |
| HSEmotion / EmotiEffLib (EfficientNet-B0/B2, MobileNet) | 7/8 basic emotions + valence/arousal | AffectNet-7 64.6-66.5 %, AffectNet-8 61-63 % [O: P3] | 14-30 MB, 16-191 ms on Snapdragon 888 CPU [O: P3] | Apache-2.0, commercial OK [O: P3] | Poor: wrong label set, ~35 % error in the wild |
| Lightweight FER CNNs (ZenNet-SA, EfficientFace, GhostNet LWFER) | basic emotions | RAF-DB 87-88.5 %, AffectNet-7 62-65 %, <1 M params, 17 ms on SD865 [S: P5] | tiny | varies | Same label-set problem |
| DFER temporal (DFEW / FERV39k models, Mamba / ConvLSTM) | emotion per clip | in-the-wild UAR gains are small [S: P9]; CK+ 93 %, MMI 68 % [O: P6] | clip-based, adds latency | varies | Not worth it: the stabiliser already supplies temporal context |

Conversion path for the MediaPipe models (my judgement, not verified end-to-end): coremltools converts from
PyTorch/TF, not from TFLite. Go TFLite → ONNX (`tflite2onnx` [S: P10], or the existing Apache-2.0 ONNX export of
FaceMesh V2 with parity checks [O: P4]) → `onnx2torch` → `coremltools.convert` (fp16, `.all` compute units). Feed
Vision's face bounding box as the crop, so BlazeFace is not needed. Expected M1 cost: a few ms per frame on
ANE/GPU (my extrapolation from the Pixel 6 numbers). Verify with Instruments.

Is the geometric approach still competitive? For our classes, yes, with caveats. (a) Posed expressions are where geometry
is strongest [S: P7; O: P6]. (b) Better landmark accuracy "does not necessarily guarantee a gain" in FER [O: P11],
so a fancier landmark model is no automatic win. (c) Neutral-face subtraction / personal baselines measurably help
[S: P12]. (d) The weak class for every method is **sad** (subtle, confused with neutral): a 2025 blendshape+LSTM study
was weakest on happy-vs-sad and reports that a non-temporal net "oscillat[ed] between classes without visual changes"
on live video [O: P13]. Our `sad` uses only mouth-corner drop. Add AU1/AU4 cues (inner-brow raise, brow knit) from
Vision's brow points (R6).

### 2.3 Hand gestures
- **HaGRIDv2** (Dec 2024): 1,086,158 FullHD images, 33 gestures + `no_gesture`, 65,977 people; split by subject.
  The richer `no_gesture` set (hands near the face, holding a cup, gesticulating) gave "6 times fewer false positive errors" [O: H2].
  Full-frame classifiers: ResNet18 98.3 F1 (11.2 M params), MobileNetV3-L 93.4 (4.2 M) [O: H1, H2]. The annotations include
  21-point hand keypoints **generated by MediaPipe** [O: H1, H2]. Class mapping: `like`→thumbsUp, `dislike`→thumbsDown,
  `peace`/`peace_inverted`→peace, `palm`/`stop`→openPalm, `one`/`point`→pointing, `fist`→fist,
  `hand_heart`/`hand_heart2`→heart, `no_gesture`→negatives.
- **Licence:** the repo's `license/en_us.pdf` is "not a Creative Commons license ... a reworking of ... Attribution-ShareAlike
  4.0" with ShareAlike for adapted material [O: H3]. The v2 paper describes it as for research purposes, "with restrictions
  against commercial use" [O: H2, via summary]. Whether weights trained on it are "Adapted Material" is a legal question.
  **For a commercial release, treat HaGRID as research-only** and train the shipped model on our own captures, using HaGRID
  for evaluation and prototyping.
- **MediaPipe Gesture Recognizer**: 8 canned classes (None, Closed_Fist, Open_Palm, Pointing_Up, Thumb_Down, Thumb_Up,
  Victory, ILoveYou), whole pipeline 16.8 ms CPU / 20.9 ms GPU on Pixel 6 [O: H4]. No public per-class accuracy found.
  It needs MediaPipe's own landmarks, so it brings no benefit over Vision + our own classifier.
- **Landmark classifiers:** a 63→256→128→N MLP reports 100 % on held-out ASL letters [S: H5]. A landmark DNN reports
  98.7 % / 98.2 % on simple/complex backgrounds (Tiny HGR) [O: H6]. For dynamic data, wrist-relative normalisation beat raw
  coordinates (84.7 % vs 80.6 %) [O: H7]. Apple's Create ML hand-pose classifier takes `keypointsMultiArray()` (21 joints
  × x, y, confidence), recommends **≈500 images per class**, a `Background` class containing random **and transitional**
  poses, and a **0.9 confidence threshold** [O: H8].
- What 2-D wrist-ratio rules cannot see: foreshortened fingers (pointing at the camera), thumb tucked across the palm
  versus extended, and partially occluded joints. A learned classifier handles these better than hand-tuned ratios
  (my judgement, consistent with H6).

### 2.4 Temporal stabilisation
- One Euro (Casiez): start with `mincutoff = 1 Hz, beta = 0`. Lower `mincutoff` until jitter at rest is gone, then raise
  `beta` in ×10 steps (start around 0.001) until fast motion stops lagging. Beta depends on the units of the signal [O: T1].
  MediaPipe's production pose smoothing uses `min_cutoff 0.05, beta 80, derivate_cutoff 1` on scale-normalised
  coordinates and a low-pass with `alpha 0.1` on visibility [O: T2]. Our filter runs on ratio-valued metrics (range about 0.04-1)
  with `minCutoff 1.5, beta 0.5`. That is plausible, but it was never tuned by the procedure.
- Blink vs eyes-closed: EAR threshold about 0.2. The original detector classifies a 13-frame EAR window [S: T3]. Blinks
  last ~0.1-0.4 s, and the current 0.45 s enter delay is consistent with that.
- Label smoothing: the current stabiliser (confidence-weighted 0.35 s vote, then per-class enter delay, then 0.9 s minimum hold)
  already does what the surveyed repos do, and more. I found **no 2024-2026 evidence** that HMM/Viterbi beats vote windows for this
  kind of UI. The literature on forward HMM spotting and temporal smoothing dates from 2007-2011 [S: T4]. An online forward filter
  with a "sticky" transition matrix is equivalent to a principled leaky vote. It is only worth adding if the eval harness shows
  residual flicker.
- Apple's guidance for hand-pose classifiers: do not predict on every frame for UI effects, and gate at 0.9 [O: H8].

### 2.5 Robustness and fairness
- **Head pose:** Vision gives continuous yaw/pitch [S: A8]. To first order, image inter-ocular distance shrinks by cos(yaw)
  while vertical distances do not, so `browRaise`, `cornerLift`, `mouthOpen` and `eyeOpen` (all divided by a horizontal length) are
  inflated by 1/cos(yaw). At our gate `maxHeadTurn = 0.45 rad` that is **+11 %**. For `browRaise ≈ 0.40` this is +0.044,
  i.e. **63 % of the 0.07 brow threshold from yaw alone**, which is a likely source of false "eyebrows raised" while
  the user looks sideways. Pitch compresses vertical distances by about cos(pitch), and brows and lips also shift because of
  depth. Full frontalisation (3-D canonical fit, Procrustes) is the literature answer [S: R1]. A cos-correction plus a
  tighter gate per metric is the cheap 80 % fix (judgement).
- **Personal baseline:** neutral-shape subtraction "increases the facial expression recognition rate significantly"
  [S: P12]. Keep the median-of-15-frames calibration. Consider storing several baselines keyed by coarse yaw/pitch bin (judgement).
- **Glasses/beards/lighting:** the blendshape model card warns of degradation and more "jittering" under low light,
  noise, motion and occlusion, and of failure beyond 80° turn or under 50 % visibility [O: P1]. Thick frames bias the eye contour
  and beards bias the lower-lip contour. Both are mostly absorbed by the per-user baseline, because they are constant offsets.
  Use `DetectLensSmudgeRequest` / capture quality only as soft gates [O: A3, A7].
- **Fairness:** FER models show skin-tone and gender gaps (e.g. anger↔disgust confusions 2.1× more frequent for Black
  females in large multimodal models) [S: R2]. MediaPipe Blendshapes reports a per-group MAD within 0.008 [O: P1]. Apple
  publishes no comparable numbers for Vision landmarks (as far as I found). Include diverse testers in R1.

### 2.6 Performance
- Keep one `VNImageRequestHandler` per frame with reused requests (current design). Recommended additions:
  1. Run `VNDetectFaceRectanglesRequest` (revision 3) explicitly and pass the result through `inputFaceObservations`. This
     guarantees continuous yaw/pitch and lets you skip detection: Apple's tracking sample runs `VNTrackObjectRequest` on a
     `VNSequenceRequestHandler` between detections and stops tracking below **0.3 confidence** [O: A11].
  2. Hand pose: set `regionOfInterest` to the last hand box ×1.5–2 while hands are tracked, and run the full frame every
     ~10th frame or when the hands are lost (judgement; Vision's ROI is a documented `VNImageBasedRequest` property).
  3. `preferBackgroundProcessing = true` "reduces the request's memory footprint, processing footprint, and CPU/GPU
     contention at the potential cost of longer execution time" [O: A12]. Use it for the probe-only hand pass, not for the
     face pass.
  4. Tiny Core ML models (an MLP of under 100 k params) gain nothing from the ANE. Dispatch overhead dominates and the first
     inference can take 100-300 ms [S: X1]. Use `.cpuOnly`, or plain Swift/Accelerate, and pre-warm at launch.
  5. The capture runs at 1280x720 30 fps, and Vision rescales internally. Keep it, because output needs 720p. Do not add a
     separate downscale pass, which costs more than it saves (judgement).

## 3. Ranked recommendations

| # | Recommendation | Expected gain | Cost | Risk |
|---|---|---|---|---|
| R1 | **Eval and replay harness**: record ~10 people × {daylight, dim, backlit} × {glasses, none} × each class plus 60 s of "talking neutral". Store `FrameObservation` JSON per frame, replay through `ReactionClassifier` + `ReactionStabilizer` in `swift test`. Metrics: per-class F1, time-to-switch, **false switches/min on neutral** (target < 0.5) | Makes every other item measurable. Today's tuning is by eye | M (2-3 days), no deps | none |
| R2 | **Pose-correct the face metrics**: multiply `mouthOpen, cornerLift, browRaise, eyeOpen` by cos(yaw) and the vertical terms by 1/cos(pitch). Use per-metric gates (brows/sad abstain beyond ~0.30 rad; smile/open allowed to 0.45). Make the face detector revision 3 and `constellation76Points` explicit, and log yaw to verify it is continuous | Removes up to an 11 % systematic bias (≈0.6 of the brow threshold) at the gate. Fewer false brows/sad when looking aside | S (½ day) | low; check that pitch correction does not over-correct (R1) |
| R3 | **Learned static hand-shape classifier** on Vision keypoints: Create ML `MLHandPoseClassifier` or a 42→64→32→7 MLP on wrist-centred, palm-size-scaled, chirality-mirrored (x, y). Classes: thumbsUp, thumbsDown, peace, openPalm, pointing, fist, none. Data: ≥500/class [O: H8]. Prototype on HaGRIDv2 images **re-landmarked with macOS 26 Vision** (not the shipped MediaPipe keypoints), ship on own captures. Accept only if p ≥ 0.9 [O: H8]; otherwise fall back to the rules | Expect ~95-99 % on clean frontal hands (H6, S: H5) vs. rule failures on foreshortened and rotated hands. The `none` class (incl. HaGRIDv2 `no_gesture`) cuts false positives (6× in H2) | M (3-5 days). Model < 100 KB (judgement), < 0.1 ms CPU | HaGRID licence (research only / SA). Domain shift from the new macOS 26 hand model, so always extract with the same OS model as shipped |
| R4 | **Retune hand rule thresholds for the macOS 26 hand model** (`1.15`, `0.55 × palm`, `1.1`, thumb-margin `0.15 × palm`) using R1 recordings, since joint locations changed [O: A3] | Restores rule accuracy that silently shifted with the OS | S | low |
| R5 | **One Euro tuning by the Casiez procedure**, per metric: beta=0, lower mincutoff until static jitter < ~10 % of the threshold, then raise beta ×10 until a 150 ms expression onset is not delayed by > 1 frame. Smooth hand keypoints too (mincutoff ≈ 1 Hz) before ratio tests | Less jitter near thresholds, so fewer hysteresis crossings | S | low |
| R6 | **Better "sad" and "surprised"**: add inner-brow height minus outer-brow height (AU1, sad/surprise) and inter-brow distance / IOD (AU4, frown) from the Vision brow points. Sad = corner drop AND (AU1 or AU4) above baseline. Surprised gains a small boost from browRaise | Sad is the weakest class everywhere (P13). Requiring 2 cues cuts neutral→sad false positives | S-M | brow points in the 76-pt constellation are sparse (check index stability) |
| R7 | **Face tracking + ROI pipeline** (2.6.1-2.6.3) | ~20-40 % less Vision time per frame (judgement, measure in Instruments). Steadier bounding boxes, hence steadier landmarks | M | tracker drift; re-detect every N frames |
| R8 | **Phase-2 experiment: MediaPipe FaceMesh V2 + Blendshapes V2 in Core ML**, used as a second opinion (or replacement) for the face classes, still baseline-subtracted per user. Map: jawOpen→open, mouthSmile→smile, eyeBlink→eyesClosed, browInnerUp/browOuterUp→brows, mouthFrown+browInnerUp→sad | Semantically richer, trained on millions of samples with a fairness check [O: P1, P2]. Likely gains on sad and brows. Unknown vs. our tuned geometry until R1 measures it | L (1-2 weeks incl. conversion + parity tests). ~ a few MB fp16 (judgement) | conversion op support. Second model on an 8 GB machine. Crop mismatch Vision bbox vs BlazeFace |
| R9 | **Stabiliser refinements** only if R1 shows residual flicker: replace the hard window with an exponential evidence accumulator (sticky forward filter, self-transition ~0.97 at 30 fps); make enter thresholds class-specific (gestures 0.12 s, blink-safe eyes 0.45 s, as now) | Marginal | S | low |
| R10 | Do **not** adopt basic-emotion CNNs (HSEmotion, AffectNet models) or DFER video models | Avoids 16-30 MB of models with ~35 % in-the-wild error and the wrong label set | none | n/a |

Suggested order: R1 → R2 → R4 → R5 → R3 → R6 → R7 → (R8 only if R1 shows face accuracy is still the bottleneck).

## 4. Concrete thresholds worth reusing
- Hand classifier acceptance: p ≥ 0.9, with ≥500 samples/class and a transitional "background" class [O: H8].
- Tracker continuation: VNTrackObjectRequest confidence > 0.3, else re-detect [O: A11].
- Blink: EAR ≈ 0.2, so eyes-closed should require more than ~0.4 s [S: T3]. Current 0.45 s is fine.
- One Euro: start 1 Hz / beta 0 [O: T1]. MediaPipe pose: 0.05 Hz / beta 80 on normalised coordinates, visibility alpha 0.1 [O: T2].
- Blendshape thresholds used by open-source meme apps (for R8): jawOpen > 0.28 open, smile > 0.35 clear, browDown > 0.35
  angry, eyeOpen < 0.22 (see `docs/research.md`).
- Yaw bias of IOD-normalised vertical metrics: 1/cos(yaw) → +2 % at 0.2 rad, +6 % at 0.35, +11 % at 0.45 (geometry).

## 5. References
`[O]` opened and read (fully or the relevant part); `[S]` seen only in search results or snippets, not verified.

Apple
- A1 [O] ARFaceAnchor.blendShapes (iOS/iPadOS only): https://developer.apple.com/documentation/arkit/arfaceanchor/blendshapes
- A2 [O] DetectHumanHandPoseRequest: https://developer.apple.com/documentation/vision/detecthumanhandposerequest
- A3 [O] WWDC25 "Read documents using the Vision framework" (hand-pose model replaced, lens smudge): https://developer.apple.com/videos/play/wwdc2025/272/
- A4 [O] WWDC26 "What's new in image understanding": https://developer.apple.com/videos/play/wwdc2026/237/
- A5 [O] Forum: "Updated DetectHandPoseRequest revision from WWDC25 doesn't exist": https://developer.apple.com/forums/thread/803595
- A6 [O] DetectFaceLandmarksRequest: https://developer.apple.com/documentation/vision/detectfacelandmarksrequest
- A7 [O] WWDC21 "Detect people, faces, and poses using Vision": https://developer.apple.com/videos/play/wwdc2021/10040/
- A8 [S] Kodeco, "Vision Tutorial: What's new with face detection" (continuous yaw/pitch in rev 3): https://www.kodeco.com/29023965-vision-tutorial-for-ios-what-s-new-with-face-detection?page=2
- A9 [O] VNDetectFaceLandmarksRequest.constellation: https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest/constellation
- A10 [O] Forum: "macOS: Is ARKit-equivalent face tracking possible with an external camera?": https://developer.apple.com/forums/thread/815515
- A11 [O] Sample "Tracking the User's Face in Real Time": https://developer.apple.com/documentation/vision/tracking-the-user-s-face-in-real-time
- A12 [O] VNRequest.preferBackgroundProcessing: https://developer.apple.com/documentation/vision/vnrequest/preferbackgroundprocessing

Face / expressions
- P1 [O] MediaPipe Blendshape V2 model card (PDF): https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Blendshape%20V2.pdf
- P2 [O] Grishchenko et al., "Blendshapes GHUM", arXiv 2309.05782: https://arxiv.org/abs/2309.05782 ; MediaPipe Face Landmarker guide: https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker
- P3 [O] EmotiEffLib (HSEmotion) repo: https://github.com/sb-ai-lab/EmotiEffLib
- P4 [O] Face Mesh V2 ONNX conversion (Apache-2.0): https://huggingface.co/fernandotonon/QtMeshEditor-facemesh-onnx
- P5 [S] Lightweight FER results (ZenNet-SA, EfficientFace, LWFER): https://pure.seoultech.ac.kr/en/publications/zennet-sa-an-efficient-lightweight-neural-network-with-shuffle-at/ , https://www.mdpi.com/1424-8220/24/18/5868
- P6 [O] "Deep Learning-Based Real-Time Sequential Facial Expression Analysis Using Geometric Features", arXiv 2512.05669: https://arxiv.org/abs/2512.05669
- P7 [S] Geometric FER on CK+ (88.7 %, 97.8 %): https://arxiv.org/abs/1701.01879
- P8 [S] MediaPipe Face Landmarker for iOS (CocoaPods): https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/ios
- P9 [S] DFER 2025 (text-guided weakly supervised): https://arxiv.org/pdf/2511.10958
- P10 [S] tflite2onnx: https://pypi.org/project/tflite2onnx/
- P11 [O] "Impact of facial landmark localization on facial expression recognition", arXiv 1905.10784: https://arxiv.org/abs/1905.10784
- P12 [S] Neutral-face estimation / BAUFER baseline: https://acikerisim.bahcesehir.edu.tr/entities/publication/93064102-bab1-423e-915e-f755c1b898f6/full , https://research.chalmers.se/en/publication/534271
- P13 [O] "Emotion estimation from video footage with LSTM" (MediaPipe blendshapes), arXiv 2501.13432: https://arxiv.org/html/2501.13432v3

Hands
- H1 [O] HaGRID repo (v2 classes, model zoo, MediaPipe keypoints): https://github.com/hukenovs/hagrid
- H2 [O] HaGRIDv2 paper, arXiv 2412.01508: https://arxiv.org/html/2412.01508v1
- H3 [O] HaGRID licence PDF: https://github.com/hukenovs/hagrid/blob/master/license/en_us.pdf
- H4 [O] MediaPipe Gesture Recognizer guide: https://developers.google.com/edge/mediapipe/solutions/vision/gesture_recognizer
- H5 [S] ASL landmark MLP: https://huggingface.co/nocontextdoruk/asl-landmark-mlp
- H6 [O] Gil-Martín et al., "Hand Pose Recognition through MediaPipe Landmarks": https://oa.upm.es/84969/
- H7 [O] "Hand Gesture Recognition Using MediaPipe Landmarks and Deep Learning Networks" (IPN Hand, 2025): https://scitepress.org/PublishedPapers/2025/130535
- H8 [O] WWDC21 "Classify hand poses and actions with Create ML": https://developer.apple.com/videos/play/wwdc2021/10039/

Temporal / robustness / perf
- T1 [O] 1€ filter page (Casiez): https://gery.casiez.net/1euro
- T2 [O] MediaPipe pose_landmark_filtering.pbtxt: https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/modules/pose_landmark/pose_landmark_filtering.pbtxt
- T3 [S] Soukupová & Čech 2016, EAR blink detection: https://vision.fe.uni-lj.si/cvww2016/proceedings/papers/05.pdf
- T4 [S] Forward-spotting accumulative HMMs for gestures: https://poasis.postech.ac.kr/handle/2014.oak/23245
- R1 [S] Expression-preserving frontalisation (Kang et al., ICCVW 2021): https://openaccess.thecvf.com/content/ICCV2021W/TradiCV/html/Kang_Robust_Face_Frontalization_for_Visual_Speech_Recognition_ICCVW_2021_paper.html
- R2 [S] FER bias in multimodal models, arXiv 2408.14842: https://arxiv.org/abs/2408.14842
- X1 [S] Core ML / ANE small-model overhead discussion (whisper.cpp): https://github.com/ggerganov/whisper.cpp/discussions/548
