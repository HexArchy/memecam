"""Export trained weights to the MemeCam JSON model + golden test vectors.

Usage:
    uv run --with numpy python -I export.py <weights.npz> <dataset.npz> <model_out.json> <golden_out.json>

Expected outputs in the golden file are computed in float64 from the 6-decimal-rounded
weights exactly as written to the model JSON, so a Swift port must match within 1e-4.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402

from features import LABELS, PARENT, fill_missing, normalize  # noqa: E402

JOINTS = ["wrist", "thumbCMC", "thumbMP", "thumbIP", "thumbTip",
          "indexMCP", "indexPIP", "indexDIP", "indexTip",
          "middleMCP", "middlePIP", "middleDIP", "middleTip",
          "ringMCP", "ringPIP", "ringDIP", "ringTip",
          "littleMCP", "littlePIP", "littleDIP", "littleTip"]

NORMALIZATION = {
    "input": "21 hand joints in MemeCam aspect space: x = visionX * imageWidth/imageHeight, y = visionY "
             "(y up, Vision convention). Uniform scale/translation of the input does not matter; "
             "anisotropic scaling does, so x must be aspect-corrected.",
    "jointOrder": JOINTS,
    "missingJoints": "wrist (0) and middleMCP (9) are required, else no prediction. For j = 1...20 in "
                     "increasing order, a missing joint j takes the (already filled) position of parent[j].",
    "parent": PARENT.tolist(),
    "steps": [
        "q_i = p_i - p_0 for i in 0...20",
        "v = q_9; s = max(sqrt(v.x^2 + v.y^2), 1e-6); ux = v.x / s; uy = v.y / s",
        "x'_i = (uy * q_i.x - ux * q_i.y) / s;  y'_i = (ux * q_i.x + uy * q_i.y) / s   "
        "(rotates wrist->middleMCP onto +y, unit length)",
        "features = [x'_0, y'_0, x'_1, y'_1, ..., x'_20, y'_20, ux, uy]  (44 floats; ux, uy = original "
        "orientation of wrist->middleMCP; (0, 1) = fingers up)",
    ],
    "mirroring": "none at inference: the model was trained with random x-mirroring and is chirality-agnostic",
    "forward": "h = relu(W0 x + b0); h = relu(W1 h + b1); probs = softmax(W2 h + b2) (weights are out x in)",
    "featureCount": 44,
}


def forward(layers, x):
    h = x
    for L in layers:
        h = h @ np.asarray(L["weights"], dtype=np.float64).T + np.asarray(L["bias"], dtype=np.float64)
        if L["activation"] == "relu":
            h = np.maximum(h, 0)
        else:
            logits = h
            e = np.exp(h - h.max(1, keepdims=True))
            h = e / e.sum(1, keepdims=True)
    return logits, h


def r6(a):
    return np.round(np.asarray(a, dtype=np.float64), 6).tolist()


def main(w_path, ds_path, model_out, golden_out):
    w = np.load(w_path)
    labels = [str(s) for s in w["labels"]]
    assert labels == LABELS
    layers = [
        {"weights": r6(w["W0"]), "bias": r6(w["b0"]), "activation": "relu"},
        {"weights": r6(w["W1"]), "bias": r6(w["b1"]), "activation": "relu"},
        {"weights": r6(w["W2"]), "bias": r6(w["b2"]), "activation": "softmax"},
    ]
    model = {
        "version": 1,
        "labels": labels,
        "normalization": NORMALIZATION,
        "training": {
            "data": "HaGRID v2 MediaPipe hand_landmarks (annotations_with_landmarks), official user_id splits",
            "license": "HaGRID licence (CC BY-SA 4.0 variant, research / non-commercial); weights are for "
                       "personal, non-commercial use",
            "architecture": "44-128-64-%d MLP, ReLU, softmax" % len(labels),
        },
        "layers": layers,
    }
    with open(model_out, "w") as f:
        json.dump(model, f, separators=(",", ":"))

    # Golden vectors: 5 real (correctly classified) test hands in Vision convention; one rotated
    # by 25 deg, one with missing fingertips.
    d = np.load(ds_path)
    X, y = d["X_test"].astype(np.float64), d["y_test"]
    rng = np.random.default_rng(7)
    picks = []
    for lab in ["thumbsUp", "thumbsDown", "peace", "fist", "none"]:
        cand = np.nonzero(y == LABELS.index(lab))[0]
        Pn = normalize(X[cand])
        _, pr = forward(layers, Pn)
        good = cand[pr.argmax(1) == LABELS.index(lab)]
        picks.append(int(rng.choice(good)))
    cases = []
    for ci, i in enumerate(picks):
        pts = X[i].copy()
        present = np.ones(21, dtype=bool)
        if ci == 3:  # fist: drop two fingertips like Vision does for occluded fingers
            present[[8, 12]] = False
        if ci == 0:  # rotate thumbs-up by 25 deg to exercise orientation features
            c0, s0 = np.cos(np.deg2rad(25)), np.sin(np.deg2rad(25))
            q = pts - pts[0]
            pts = pts[0] + np.stack([c0 * q[:, 0] - s0 * q[:, 1], s0 * q[:, 0] + c0 * q[:, 1]], 1)
        pts = np.round(pts, 6)
        filled = fill_missing(pts[None], present[None])[0]
        feats = normalize(filled[None])
        logits, probs = forward(layers, feats)
        cases.append({
            "hagridLabel": str(d["src_names"][d["src_test"][i]]),
            "expectedLabel": LABELS[int(probs.argmax())],
            "joints": {JOINTS[j]: (None if not present[j] else [float(pts[j, 0]), float(pts[j, 1])])
                       for j in range(21)},
            "features": np.round(feats[0], 8).tolist(),
            "logits": np.round(logits[0], 8).tolist(),
            "probabilities": np.round(probs[0], 8).tolist(),
        })
    golden = {
        "version": 1,
        "model": os.path.basename(model_out),
        "labels": LABELS,
        "tolerance": 1e-4,
        "note": "joints are in MemeCam aspect space (y up). null = joint not returned by Vision. "
                "features/logits/probabilities computed in float64 with the model JSON's rounded weights.",
        "normalization": NORMALIZATION,
        "cases": cases,
    }
    with open(golden_out, "w") as f:
        json.dump(golden, f, indent=1)
    for c in cases:
        print(c["hagridLabel"], "->", c["expectedLabel"], round(max(c["probabilities"]), 4))
    print("model bytes:", os.path.getsize(model_out), "golden bytes:", os.path.getsize(golden_out))


if __name__ == "__main__":
    main(*sys.argv[1:5])
