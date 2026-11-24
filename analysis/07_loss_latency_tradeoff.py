#!/usr/bin/env python3
"""Kompromis gubitak/latencija po varijanti pri zasicenju deljenog jezgra (uzak RPS, isti red, P=450k).
Ulaz: results/processed/rev_summary.json (interferencija) i self_load_runs.csv (samoopterecenje). Izlaz: results/tables/table_loss_latency.tex
"""
import csv, json, os, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
import sys as _sys; _sys.path.insert(0, HERE)
from common import PROC, TAB, FIG, gen_file
S = json.load(open(os.path.join(PROC, "rev_summary.json")))
SELF = list(csv.DictReader(open(os.path.join(PROC, "self_load_runs.csv"))))


def f(x, d=2):
    return "--" if x is None else f"{x:.{d}f}".replace(".", "{,}")


def rng(a, b, d=2):
    return f(a, d) if f(a, d) == f(b, d) else f"{f(a, d)}--{f(b, d)}"


def self_p50(v):
    xs = [float(r["p50"]) for r in SELF if r["variant"] == v + "n" and r["load_pps"] == "450000" and r["p50"]]
    return st.median(xs) / 1000 if xs else None


L = ["% generisano: analysis/07_loss_latency_tradeoff.py", "\\begin{tabular}{@{}lccccc@{}}", "\\toprule",
     "Var. & \\makecell{Isporuka\\\\t2 / t3} & \\makecell{p50 osnovno\\\\{}[ms]} & \\makecell{p50 pri zasićenju\\\\{}[ms]} & "
     "\\makecell{U roku $\\leq$1~ms\\\\(osnovno $\\rightarrow$ zasićenje)} & \\makecell{p50 samog\\\\opterećujućeg [ms]} \\\\",
     "\\midrule"]
for v in ("A0", "A1", "A2", "A3", "A4"):
    k = f"{v}n_same"
    d2, d3 = S[f"{k}_t2_obs_deliv"], S[f"{k}_t3_obs_deliv"]
    b = [S[f"{k}_t{t}_p50_base"] / 1000 for t in (2, 3)]
    p = [S[f"{k}_t{t}_p50"] / 1000 for t in (2, 3)]
    sb = [S[f"{k}_t{t}_slo_1ms_base"] for t in (2, 3)]
    sl = [S[f"{k}_t{t}_slo_1ms"] for t in (2, 3)]
    pz = f"{f(min(p), 0 if min(p) > 100 else 1)}--{f(max(p), 0 if max(p) > 100 else 1)}"
    L.append(f"{v} & {f(d2)} / {f(d3)} & {rng(min(b), max(b))} & {pz} & "
             f"{rng(min(sb), max(sb))} $\\rightarrow$ {rng(min(sl), max(sl))} & {f(self_p50(v))} \\\\")
L += ["\\bottomrule", "\\end{tabular}"]
open(os.path.join(TAB, "table_loss_latency.tex"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
