# Third-party notices

## Memes (`Resources/Memes/*.gif`)

Reaction GIFs were collected from public Tenor pages for personal, non-commercial use. They remain the property
of their respective owners; the source URL of each file is recorded in `Resources/Memes/memes.json`.
Remove or replace them before any public or commercial distribution.

## HaGRID v2 (`Resources/Models/hand-gesture-mlp.json`)

The hand-gesture model was trained on hand landmarks from **HaGRID v2** (Kapitanov et al.,
https://github.com/hukenovs/hagrid), distributed under a modified CC BY-SA 4.0 licence that permits
non-commercial use only: https://github.com/hukenovs/hagrid/blob/master/license/en_us.pdf.
The weights are therefore for personal, non-commercial use. For commercial use retrain on your own data
(`Tools/gesture-training/`).

## MediaPipe Face Mesh V2 and Blendshapes V2 (`Resources/Models/FaceMesh.mlmodelc`, `FaceBlendshapes.mlmodelc`)

This product includes machine-learning models from Google MediaPipe (Face Mesh V2 "face_landmarks_detector" and
Blendshapes V2 "face_blendshapes", from `face_landmarker.task`, https://github.com/google-ai-edge/mediapipe),
Copyright Google LLC / The MediaPipe Authors, licensed under the Apache License, Version 2.0
(http://www.apache.org/licenses/LICENSE-2.0). Modifications: converted from TensorFlow Lite to Core ML
(fp16/fp32 mlprogram); PReLU re-expressed as relu(x) + a·min(x, 0); inputs/outputs renamed. No retraining.
`Resources/Models/blendshape-indices.json` lists the 146 landmark indices the blendshape model reads (from
MediaPipe's `face_blendshapes_graph.cc`).

## HSEmotion (`Resources/Models/HSEmotion.mlmodelc`)

This product includes the HSEmotion facial-expression model "enet_b0_8_best_vgaf" by Andrey V. Savchenko
(https://github.com/av-savchenko/face-emotion-recognition), code licensed under the Apache License 2.0. The model
weights were trained on the AffectNet dataset (Mollahosseini et al., 2017), which is licensed for non-commercial
research/educational use only; these weights are therefore used here for non-commercial purposes only.
Converted from ONNX to Core ML (fp16); ImageNet normalisation folded into the model. No retraining.
Citation: A. V. Savchenko, "Facial expression recognition with adaptive frame rate based on multiple testing
correction", ICML 2023; A. V. Savchenko, L. V. Savchenko, I. Makarov, "Classifying emotions and engagement in
online learning based on a single facial expression recognition neural network", IEEE Trans. Affective
Computing, 2022.

## Test photos (`Tests/Fixtures/golden-face/`)

Crops of "Elizabeth Gardner, WASP" (U.S. National Archives, NARA 542191), public domain, via Wikimedia Commons.

## Agent skills (`.claude/skills/`)

- `swiftui-expert-skill`, `swift-concurrency` — Antoine van der Lee (AvdLee), MIT.
- `swiftui-pro` — Paul Hudson (twostraws), MIT.

## Apple frameworks

Vision, AVFoundation, Core Image, Metal, CoreMediaIO, SystemExtensions — Apple Inc., used per the Apple
Developer Program License Agreement.
