"""Train the 44->128->64->N MLP on the prepared dataset (CPU, PyTorch).

Usage:
    uv run --with numpy --with torch python -I train.py <dataset.npz> <weights_out.npz> [epochs=40]

Writes the best (val macro-F1) weights as float32 arrays W0,b0,W1,b1,W2,b2 (W: out x in)
and prints test metrics (balanced + full natural test split, clean + augmented).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import torch  # noqa: E402
from torch import nn  # noqa: E402

from features import LABELS, augment, normalize  # noqa: E402

torch.set_num_threads(4)
NONE = LABELS.index("none")


def make_model(n_out):
    return nn.Sequential(nn.Linear(44, 128), nn.ReLU(), nn.Linear(128, 64), nn.ReLU(), nn.Linear(64, n_out))


def predict(model, X):
    model.eval()
    with torch.no_grad():
        return torch.softmax(model(torch.from_numpy(X.astype(np.float32))), dim=1).numpy()


def metrics(y, p, n):
    pred = p.argmax(1)
    cm = np.zeros((n, n), dtype=np.int64)
    np.add.at(cm, (y, pred), 1)
    tp = np.diag(cm).astype(float)
    prec = tp / np.maximum(cm.sum(0), 1)
    rec = tp / np.maximum(cm.sum(1), 1)
    f1 = 2 * prec * rec / np.maximum(prec + rec, 1e-12)
    return cm, prec, rec, f1


def report(title, y, p):
    n = len(LABELS)
    cm, prec, rec, f1 = metrics(y, p, n)
    conf = p.max(1)
    hi = conf >= 0.8
    acc = (p.argmax(1) == y).mean()
    acc_hi = (p.argmax(1)[hi] == y[hi]).mean() if hi.any() else float("nan")
    print(f"\n=== {title}: n={len(y)} acc={acc:.4f} macroF1={f1.mean():.4f} "
          f"| conf>=0.8: coverage={hi.mean():.4f} acc={acc_hi:.4f}")
    # gesture-only precision when "accept if p>=0.8, else none"
    gated = np.where(hi, p.argmax(1), NONE)
    _, gp, gr, gf = metrics(y, np.eye(n)[gated], n)
    print(f"{'class':>11} {'prec':>7} {'rec':>7} {'f1':>7} {'support':>8} | gated@0.8 prec/rec")
    for i, lab in enumerate(LABELS):
        print(f"{lab:>11} {prec[i]:7.4f} {rec[i]:7.4f} {f1[i]:7.4f} {cm[i].sum():8d} | {gp[i]:.4f}/{gr[i]:.4f}")
    print("confusion (rows=true, cols=pred):", " ".join(f"{l[:6]:>6}" for l in LABELS))
    for i, lab in enumerate(LABELS):
        print(f"{lab:>11}", " ".join(f"{v:6d}" for v in cm[i]))
    return f1.mean()


def main(ds_path, out_path, epochs=40):
    d = np.load(ds_path)
    Xtr_raw, ytr = d["X_train"], d["y_train"].astype(np.int64)
    Xva = normalize(d["X_val"]).astype(np.float32)
    yva = d["y_val"].astype(np.int64)
    n = len(LABELS)
    # per-sample sampling weights: every gesture class equal mass, "none" 2x
    counts = np.bincount(ytr, minlength=n)
    cls_mass = np.where(np.arange(n) == NONE, 2.0, 1.0)
    w = (cls_mass / counts)[ytr]
    w /= w.sum()
    per_epoch = int(cls_mass.sum() * 40000)

    torch.manual_seed(0)
    rng = np.random.default_rng(0)
    model = make_model(n)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    steps_per_epoch = per_epoch // 512
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=epochs * steps_per_epoch)
    lossf = nn.CrossEntropyLoss(label_smoothing=0.02)
    best, best_state = -1, None
    for ep in range(epochs):
        idx = rng.choice(len(ytr), per_epoch, p=w)
        X = torch.from_numpy(normalize(augment(Xtr_raw[idx], rng)).astype(np.float32))
        Y = torch.from_numpy(ytr[idx])
        model.train()
        perm = torch.randperm(len(Y))
        tot = 0.0
        for b in range(steps_per_epoch):
            bi = perm[b * 512:(b + 1) * 512]
            opt.zero_grad()
            loss = lossf(model(X[bi]), Y[bi])
            loss.backward()
            opt.step()
            sched.step()
            tot += loss.item()
        _, _, _, f1 = metrics(yva, predict(model, Xva), n)
        print(f"epoch {ep + 1:2d} loss {tot / steps_per_epoch:.4f} val macroF1 {f1.mean():.4f}", flush=True)
        if f1.mean() > best:
            best = f1.mean()
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state)
    print(f"best val macroF1 {best:.4f}")

    report("VAL (balanced)", yva, predict(model, Xva))
    yte = d["y_test"].astype(np.int64)
    report("TEST balanced, clean", yte, predict(model, normalize(d["X_test"]).astype(np.float32)))
    aug_rng = np.random.default_rng(99)
    report("TEST balanced, augmented (rot/jitter/dropout/mirror)", yte,
           predict(model, normalize(augment(d["X_test"], aug_rng)).astype(np.float32)))
    report("TEST full natural distribution, clean", d["y_test_full"].astype(np.int64),
           predict(model, normalize(d["X_test_full"]).astype(np.float32)))

    sd = model.state_dict()
    np.savez(out_path,
             W0=sd["0.weight"].numpy(), b0=sd["0.bias"].numpy(),
             W1=sd["2.weight"].numpy(), b1=sd["2.bias"].numpy(),
             W2=sd["4.weight"].numpy(), b2=sd["4.bias"].numpy(),
             labels=np.asarray(LABELS))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], *(int(a) for a in sys.argv[3:]))
