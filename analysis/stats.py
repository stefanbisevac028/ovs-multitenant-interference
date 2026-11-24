"""Statistika bez scipy-ja: bootstrap 95% CI, Mann-Whitney U (normalna aproksimacija sa korekcijom
za vezane rangove), Cliff-ov delta i Holm korekcija."""
import math

import numpy as np

RNG = np.random.default_rng(20261030)


def bootstrap_ci(x, stat=np.median, n=5000, alpha=0.05):
    x = np.asarray([v for v in x if v is not None and not math.isnan(v)], dtype=float)
    if len(x) == 0:
        return (math.nan, math.nan, math.nan)
    if len(x) == 1:
        return (float(x[0]),) * 3
    idx = RNG.integers(0, len(x), size=(n, len(x)))
    bs = np.apply_along_axis(stat, 1, x[idx])
    return (float(stat(x)), float(np.quantile(bs, alpha / 2)), float(np.quantile(bs, 1 - alpha / 2)))


def mann_whitney(a, b):
    """dvostrani p (normalna aproksimacija, korekcija za vezane rangove i kontinuitet)"""
    a = np.asarray(a, dtype=float); b = np.asarray(b, dtype=float)
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        return math.nan
    allv = np.concatenate([a, b])
    order = allv.argsort(kind="mergesort")
    ranks = np.empty(len(allv))
    sv = allv[order]
    i = 0
    while i < len(sv):
        j = i
        while j + 1 < len(sv) and sv[j + 1] == sv[i]:
            j += 1
        ranks[order[i:j + 1]] = (i + j) / 2 + 1
        i = j + 1
    u1 = ranks[:n1].sum() - n1 * (n1 + 1) / 2
    mu = n1 * n2 / 2
    _, counts = np.unique(allv, return_counts=True)
    n = n1 + n2
    var = n1 * n2 / 12 * ((n + 1) - (counts ** 3 - counts).sum() / (n * (n - 1)))
    if var <= 0:
        return 1.0
    z = (abs(u1 - mu) - 0.5) / math.sqrt(var)
    return math.erfc(max(z, 0) / math.sqrt(2))


def cliffs_delta(a, b):
    """P(a > b) - P(a < b); |d| < 0,147 zanemarljiv, < 0,33 mali, < 0,474 srednji, inace veliki"""
    a = np.asarray(a, dtype=float); b = np.asarray(b, dtype=float)
    if len(a) == 0 or len(b) == 0:
        return math.nan
    gt = (a[:, None] > b[None, :]).sum()
    lt = (a[:, None] < b[None, :]).sum()
    return float((gt - lt) / (len(a) * len(b)))


def holm(pvals):
    """Holm-Bonferroni: prilagodjene p vrednosti u istom redosledu"""
    idx = sorted(range(len(pvals)), key=lambda i: pvals[i])
    m = len(pvals); adj = [0.0] * m; run = 0.0
    for k, i in enumerate(idx):
        run = max(run, min(1.0, (m - k) * pvals[i]))
        adj[i] = run
    return adj
