"""Shared feature code: normalization (must match the Swift port exactly) and augmentation.

Coordinate convention of every input to `normalize`: MemeCam "aspect space"
(x in [0, imageWidth/imageHeight], y in [0, 1], y pointing UP), joints in Vision/MediaPipe order:

    0 wrist
    1 thumbCMC  2 thumbMP   3 thumbIP   4 thumbTip
    5 indexMCP  6 indexPIP  7 indexDIP  8 indexTip
    9 middleMCP 10 middlePIP 11 middleDIP 12 middleTip
    13 ringMCP  14 ringPIP  15 ringDIP  16 ringTip
    17 littleMCP 18 littlePIP 19 littleDIP 20 littleTip
"""
import numpy as np

LABELS = ["thumbsUp", "thumbsDown", "peace", "openPalm", "pointing", "fist", "heartHalf", "none"]

# Parent of each joint along its finger chain (wrist has none). Missing joints are replaced
# by their parent's (already filled) position, processing joints in index order 1..20.
PARENT = np.array([-1, 0, 1, 2, 3, 0, 5, 6, 7, 0, 9, 10, 11, 0, 13, 14, 15, 0, 17, 18, 19])

HAGRID_TO_LABEL = {
    "like": "thumbsUp",
    "dislike": "thumbsDown",
    "peace": "peace",
    "peace_inverted": "peace",
    "palm": "openPalm",
    "stop": "openPalm",
    "stop_inverted": "openPalm",
    "one": "pointing",
    "point": "pointing",
    "fist": "fist",
    "hand_heart": "heartHalf",
    "hand_heart2": "heartHalf",
}  # everything else (incl. no_gesture) -> "none"

EPS = 1e-6


def fill_missing(p: np.ndarray, present: np.ndarray) -> np.ndarray:
    """p: (..., 21, 2); present: (..., 21) bool. Requires wrist and middleMCP present."""
    p = p.copy()
    for j in range(1, 21):
        miss = ~present[..., j]
        if np.any(miss):
            p[..., j, :] = np.where(miss[..., None], p[..., PARENT[j], :], p[..., j, :])
    return p


def normalize(p: np.ndarray) -> np.ndarray:
    """p: (N, 21, 2) aspect-space points, y up -> (N, 44) features (float64 math).

    q_i = p_i - p_0;  v = q_9;  s = |v|;  (ux, uy) = v / s
    x'_i = (uy * qx_i - ux * qy_i) / s
    y'_i = (ux * qx_i + uy * qy_i) / s
    features = [x'_0, y'_0, x'_1, y'_1, ..., x'_20, y'_20, ux, uy]
    """
    p = np.asarray(p, dtype=np.float64)
    q = p - p[:, :1, :]
    v = q[:, 9, :]
    s = np.maximum(np.sqrt(v[:, 0] ** 2 + v[:, 1] ** 2), EPS)
    ux, uy = v[:, 0] / s, v[:, 1] / s
    qx, qy = q[..., 0], q[..., 1]
    xr = (uy[:, None] * qx - ux[:, None] * qy) / s[:, None]
    yr = (ux[:, None] * qx + uy[:, None] * qy) / s[:, None]
    feats = np.stack([xr, yr], axis=-1).reshape(len(p), 42)
    return np.concatenate([feats, ux[:, None], uy[:, None]], axis=1)


def augment(p: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Random augmentation in aspect space, applied BEFORE normalize. p: (N, 21, 2)."""
    n = len(p)
    p = p.astype(np.float64).copy()
    w = p[:, :1, :]
    q = p - w
    # mirror x (handedness unknown in HaGRID v2 -> model must be chirality-agnostic)
    mirror = rng.random(n) < 0.5
    q[mirror, :, 0] *= -1
    # anisotropic stretch (uncertain source aspect, lens distortion), then uniform scale
    q[:, :, 0] *= np.exp(rng.uniform(np.log(0.87), np.log(1.15), n))[:, None]
    q *= rng.uniform(0.9, 1.1, n)[:, None, None]
    # in-plane rotation +-20 deg
    a = np.deg2rad(rng.uniform(-20, 20, n))
    c, s = np.cos(a)[:, None], np.sin(a)[:, None]
    qx, qy = q[..., 0].copy(), q[..., 1].copy()
    q[..., 0] = c * qx - s * qy
    q[..., 1] = s * qx + c * qy
    # jitter: sigma 0.02 palm lengths
    palm = np.linalg.norm(q[:, 9, :], axis=1)
    q += rng.normal(0, 0.02, q.shape) * palm[:, None, None]
    p = q + w
    # joint dropout: simulate Vision dropping occluded joints (mostly fingertips / DIPs)
    present = np.ones((n, 21), dtype=bool)
    drop_sample = rng.random(n) < 0.25
    cand = np.array([4, 8, 12, 16, 20, 3, 7, 11, 15, 19, 6, 14, 18])
    probs = np.array([3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 1, 1, 1], dtype=float)
    probs /= probs.sum()
    idx = np.nonzero(drop_sample)[0]
    k = rng.integers(1, 4, len(idx))
    for i, kk in zip(idx, k):
        present[i, rng.choice(cand, kk, replace=False, p=probs)] = False
    return fill_missing(p, present)
