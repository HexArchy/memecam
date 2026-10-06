"""Map HaGRID v2 classes to MemeCam labels, convert to Vision convention, balance, split.

Usage:
    uv run --with numpy python -I build_dataset.py <hagrid_hands_raw.npz> <out_dataset.npz> [cap=40000]

Input is the output of extract_hagrid.py. Output points are in Vision convention
(x, y_up = 1 - y). HaGRID's raw normalized coords are used as an isotropic frame
(empirically flattest; see README "aspect" caveat). Splits are HaGRID's official
subject-disjoint (user_id) train/val/test splits.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402

from features import HAGRID_TO_LABEL, LABELS  # noqa: E402

NONE = LABELS.index("none")


def balanced_indices(y, src, src_names, cap, none_cap, rng):
    keep = []
    for li in range(len(LABELS)):
        idx = np.nonzero(y == li)[0]
        if li != NONE:
            keep.append(rng.permutation(idx)[:cap])
            continue
        # none: up to 40% from no_gesture, the rest spread evenly over the other "none" classes
        ng = src_names.index("no_gesture")
        ng_idx = idx[src[idx] == ng]
        take_ng = rng.permutation(ng_idx)[: int(none_cap * 0.4)]
        others = [idx[src[idx] == s] for s in np.unique(src[idx]) if s != ng]
        remaining = none_cap - len(take_ng)
        per = remaining // max(len(others), 1)
        picks = [rng.permutation(o)[:per] for o in others]
        keep.append(np.concatenate([take_ng] + picks))
    return np.sort(np.concatenate(keep))


def main(raw_path, out_path, cap=40000):
    d = np.load(raw_path)
    names = [str(s) for s in d["label_names"]]
    lut = np.array([LABELS.index(HAGRID_TO_LABEL.get(n, "none")) for n in names], dtype=np.int64)
    src = d["label"].astype(np.int64)
    y = lut[src]
    split = d["split"]
    user = d["user"]
    pts = d["landmarks"].astype(np.float32)
    pts[..., 1] = 1.0 - pts[..., 1]  # MediaPipe y-down -> Vision y-up

    tr_u, va_u, te_u = (set(np.unique(user[split == s]).tolist()) for s in range(3))
    print("user overlap train/val:", len(tr_u & va_u), "train/test:", len(tr_u & te_u), "val/test:", len(va_u & te_u))

    rng = np.random.default_rng(1234)
    out = {"labels": np.asarray(LABELS)}
    scale = {0: 1.0, 1: 0.15, 2: 0.15}
    for s, name in enumerate(["train", "val", "test"]):
        m = np.nonzero(split == s)[0]
        c = int(cap * scale[s])
        sel = m[balanced_indices(y[m], src[m], names, c, 2 * c, rng)]
        out[f"X_{name}"] = pts[sel]
        out[f"y_{name}"] = y[sel].astype(np.int8)
        out[f"src_{name}"] = src[sel].astype(np.int16)
        out[f"user_{name}"] = user[sel]
        print(name, {LABELS[i]: int((y[sel] == i).sum()) for i in range(len(LABELS))})
    # full, unbalanced test split (natural HaGRID distribution) for a second report
    m = np.nonzero(split == 2)[0]
    out["X_test_full"] = pts[m]
    out["y_test_full"] = y[m].astype(np.int8)
    out["src_test_full"] = src[m].astype(np.int16)
    out["src_names"] = np.asarray(names)
    print("test_full", {LABELS[i]: int((y[m] == i).sum()) for i in range(len(LABELS))})
    np.savez_compressed(out_path, **out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], *(int(a) for a in sys.argv[3:]))
