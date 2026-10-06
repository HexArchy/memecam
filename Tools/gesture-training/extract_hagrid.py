"""Extract per-hand MediaPipe landmarks from HaGRID v2 annotation JSONs into one compact .npz.

Usage:
    uv run --with numpy python -I extract_hagrid.py <annotations_dir> <out.npz>

<annotations_dir> contains train/ val/ test/ subfolders with <class>.json files
(from annotations_with_landmarks/annotations.zip). Files are loaded one at a time to
keep peak memory low. Coordinates are stored raw (normalized image coords, y DOWN,
MediaPipe convention), float32.
"""
import json
import os
import sys

import numpy as np

SPLITS = ["train", "val", "test"]


def main(ann_dir: str, out_path: str) -> None:
    lm_chunks, label_chunks, user_chunks, split_chunks, img_chunks, nh_chunks = [], [], [], [], [], []
    labels: dict[str, int] = {}
    users: dict[str, int] = {}
    img_counter = 0
    skipped = 0
    for si, split in enumerate(SPLITS):
        d = os.path.join(ann_dir, split)
        if not os.path.isdir(d):
            continue
        for fname in sorted(os.listdir(d)):
            if not fname.endswith(".json"):
                continue
            with open(os.path.join(d, fname), "rb") as f:
                data = json.load(f)
            lms, labs, uids, imgs, nhs = [], [], [], [], []
            for _key, ann in data.items():
                hl = ann.get("hand_landmarks") or []
                lb = ann.get("labels") or []
                uid = users.setdefault(ann.get("user_id", ""), len(users))
                n_hands = len(lb)
                for h, lab in enumerate(lb):
                    pts = hl[h] if h < len(hl) else None
                    if not pts or len(pts) != 21:
                        skipped += 1
                        continue
                    lms.append(pts)
                    labs.append(labels.setdefault(lab, len(labels)))
                    uids.append(uid)
                    imgs.append(img_counter)
                    nhs.append(n_hands)
                img_counter += 1
            del data
            if lms:
                lm_chunks.append(np.asarray(lms, dtype=np.float32))
                label_chunks.append(np.asarray(labs, dtype=np.int16))
                user_chunks.append(np.asarray(uids, dtype=np.int32))
                img_chunks.append(np.asarray(imgs, dtype=np.int32))
                nh_chunks.append(np.asarray(nhs, dtype=np.int8))
                split_chunks.append(np.full(len(lms), si, dtype=np.int8))
            print(f"{split}/{fname}: {len(lms)} hands", flush=True)
    label_names = [None] * len(labels)
    for k, v in labels.items():
        label_names[v] = k
    np.savez_compressed(
        out_path,
        landmarks=np.concatenate(lm_chunks),
        label=np.concatenate(label_chunks),
        label_names=np.asarray(label_names),
        user=np.concatenate(user_chunks),
        image=np.concatenate(img_chunks),
        n_hands=np.concatenate(nh_chunks),
        split=np.concatenate(split_chunks),
        split_names=np.asarray(SPLITS),
    )
    print(f"done; skipped hands without 21 landmarks: {skipped}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
