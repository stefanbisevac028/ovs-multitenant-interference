#!/usr/bin/env python3
"""Kriterijumi ishoda hipoteza (revizija): P=450k prema P=0 po celiji, varijanti, tenantu i metrici.
Mann-Whitney, Cliff-ov delta, Holm na celoj familiji (60 poredjenja). Izlaz:
results/processed/rev_tests_vs_P0.csv
"""
import csv, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
import sys as _sys; _sys.path.insert(0, HERE)
from common import PROC, TAB, FIG, gen_file
sys.path.insert(0, HERE)
from stats import mann_whitney, cliffs_delta, holm

R = list(csv.DictReader(open(os.path.join(PROC, "interference_runs.csv"))))
rows, ps = [], []
for var in "A0n A1n A2n A3n A4n A0w A1w A2w A3w A4w".split():
    for cfg in ("same", "diff"):
        for t in ("2", "3"):
            for m in ("obs_deliv", "p50"):
                def g(P):
                    return [float(r[m]) for r in R if r["variant"] == var and r["cfg"] == cfg
                            and r["tenant"] == t and r["load_pps"] == P and r[m] not in ("", None)]
                a, b = g("450000"), g("0")
                if len(a) < 3 or len(b) < 3:
                    continue
                p = mann_whitney(a, b)
                p = p[1] if isinstance(p, tuple) else p
                rows.append([var[-1], cfg, var[:2], m, t, len(a), len(b), round(cliffs_delta(a, b), 3), p])
                ps.append(p)
out = os.path.join(PROC, "rev_tests_vs_P0.csv")
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["rps", "cfg", "variant", "metric", "tenant", "n_450", "n_0", "delta", "p", "p_holm"])
    for r, h in zip(rows, holm(ps)):
        w.writerow(r + [h])
print(out, len(rows))
