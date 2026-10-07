# Hand-gesture MLP training (HaGRID v2 landmarks)

Trains `Resources/Models/hand-gesture-mlp.json`: a 44→128→64→8 MLP over one hand's 21 joints.
Labels: `thumbsUp, thumbsDown, peace, openPalm, pointing, fist, heartHalf, none`.
The normalization spec lives in the model JSON (`normalization`) and in `features.py`.
`hand-gesture-mlp.golden.json` holds 5 test hands with expected features, logits and probabilities
for verifying the Swift port (tolerance 1e-4).

**Licence:** HaGRID is under a CC BY-SA 4.0 variant restricted to non-commercial use
(https://github.com/hukenovs/hagrid/blob/master/license/en_us.pdf). These weights are for personal,
non-commercial use only. Don't ship them commercially; retrain on your own captures for that.

## Reproduce

```sh
D=/path/to/workdir            # untrusted data lives here, not next to the scripts
mkdir -p $D/raw && cd $D/raw
curl -LO https://rndml-team-cv.obs.ru-moscow-1.hc.sbercloud.ru/datasets/hagrid_v2/annotations_with_landmarks/annotations.zip  # ~720 MB, no images
unzip -q annotations.zip -x '*.ipynb_checkpoints*'

T=$(git rev-parse --show-toplevel)/Tools/gesture-training
M=$(git rev-parse --show-toplevel)/Resources/Models
cd $T
uv run --no-project --with numpy python -I extract_hagrid.py $D/raw/annotations $D/hagrid_hands_raw.npz   # ~1.3M hands, ~200 MB
uv run --no-project --with numpy python -I build_dataset.py  $D/hagrid_hands_raw.npz $D/hagrid_gestures_dataset.npz
uv run --no-project --with numpy --with torch python -I train.py $D/hagrid_gestures_dataset.npz $D/weights.npz 40   # ~2 min on M1
uv run --no-project --with numpy python -I export.py $D/weights.npz $D/hagrid_gestures_dataset.npz \
    $M/hand-gesture-mlp.json $M/hand-gesture-mlp.golden.json
```

The scripts add their own directory to `sys.path` because `-I` drops it.

## Pipeline notes

- **Classes:** like→thumbsUp, dislike→thumbsDown, peace/peace_inverted→peace,
  palm/stop/stop_inverted→openPalm, one/point→pointing, fist→fist,
  hand_heart/hand_heart2→heartHalf (each hand). Everything else, including `no_gesture`, maps to none.
- **Balance:** train caps each gesture at 40k hands. `none` is capped at 80k: at most 40% comes from
  `no_gesture` and the rest is split evenly across the 22 other classes. Each training epoch samples
  every gesture with equal weight and `none` at twice that weight. Val/test use the same caps
  scaled by 0.15. A full, unbalanced test split is also reported.
- **Splits:** HaGRID's official train/val/test splits, which are disjoint by `user_id`.
- **Aspect:** HaGRID landmarks are image-normalized, and image sizes aren't in the annotations.
  The raw normalized frame looked the most isotropic: the palm length/width ratio stays flat
  across hand roll at an x-scale of about 1.0–1.15, versus 0.56 for a 1080×1920 portrait frame.
  So the raw coordinates are used as-is, and training adds a random x-stretch of 0.87–1.15.
- **Augmentation** (before normalization): random x-mirror (HaGRID v2 has no handedness, so the
  model is chirality-agnostic and inference doesn't mirror), x-stretch, scale 0.9–1.1, rotation ±20°,
  Gaussian jitter σ = 0.02 palm lengths, and dropout of 1–3 tip/DIP/PIP joints in 25% of samples
  (each dropped joint is filled from its parent).
