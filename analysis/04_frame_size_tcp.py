#!/usr/bin/env python3
"""Revizija 2: velicina okvira (64/512/1400 B) i TCP segmenti opterecujuceg toka.
Uzak RPS, isti red (deljeno jezgro), varijante A0, A2, A4; 64 B UDP iz osnovne kampanje (A?n, same).
Izlaz: results/tables/table_frame_size_tcp.tex, results/processed/rev2_extra.json, rev2_tests.csv
"""
import csv, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
import sys as _sys; _sys.path.insert(0, HERE)
from common import PROC, TAB, FIG, gen_file
sys.path.insert(0, HERE)
from stats import mann_whitney, cliffs_delta, holm  # noqa: E402

R = list(csv.DictReader(open(os.path.join(PROC, "interference_runs.csv"))))
COND = [("", "UDP 64~B"), ("_f512", "UDP 512~B"), ("_f1400", "UDP 1400~B"), ("_tcp", "TCP 64~B")]
LOADS = ["0", "150000", "300000", "450000"]


def vals(var, t, P, m):
    return [float(r[m]) for r in R if r["variant"] == var and r["cfg"] == "same" and r["tenant"] == t
            and r["load_pps"] == P and r.get(m) not in ("", None)]


def med(x):
    x = sorted(x)
    n = len(x)
    return None if not n else (x[n // 2] if n % 2 else (x[n // 2 - 1] + x[n // 2]) / 2)


def num(x, d=2):
    return "--" if x is None else f"{x:.{d}f}".replace(".", "{,}")


S, tests = {}, []
L = ["% generisano: analysis/04_frame_size_tcp.py", "\\begin{tabular}{@{}llrrrrrr@{}}", "\\toprule",
     "Opterećenje & Var. & \\multicolumn{3}{c}{isporuka t2 / t3 pri cilju [kpps]} & \\makecell{Jezgro pri 450\\\\{}[kpps]} & "
     "\\makecell{Ostv. opt.\\\\pri 450 [kpps]} & \\makecell{Odbačeno\\\\pri 450 [kpps]} \\\\",
     "\\cmidrule(lr){3-5}", " & & 150 & 300 & 450 & & & \\\\", "\\midrule"]
for suf, cname in COND:
    for v in ("A0", "A2", "A4"):
        var = f"{v}n{suf}"
        cells = []
        for P in LOADS[1:]:
            d2, d3 = med(vals(var, "2", P, "obs_deliv")), med(vals(var, "3", P, "obs_deliv"))
            S[f"{var}_{P}_d2"], S[f"{var}_{P}_d3"] = d2, d3
            cells.append(f"{num(d2)} / {num(d3)}")
        core = med(vals(var, "2", "450000", "tier0_pps"))
        off = med(vals(var, "2", "450000", "offered_load_pps"))
        drop = med(vals(var, "2", "450000", "softnet_drop_pps"))
        S[f"{var}_core450"], S[f"{var}_off450"], S[f"{var}_drop450"] = core, off, drop
        L.append(f"{cname if v == 'A0' else ''} & {v} & " + " & ".join(cells) +
                 f" & {num(core / 1e3 if core else None, 0)} & {num(off / 1e3 if off else None, 0)} & "
                 f"{num(drop / 1e3 if drop is not None else None, 1)} \\\\")
        # testovi pri 450: isporuka prema P=0 (oba tenanta) i prema A0 iste kolone
        for t in ("2", "3"):
            a, b = vals(var, t, "450000", "obs_deliv"), vals(var, t, "0", "obs_deliv")
            if len(a) >= 3 and len(b) >= 3:
                tests.append({"cond": suf or "_64", "variant": v, "tenant": t, "vs": "P0",
                              "p": mann_whitney(a, b), "delta": cliffs_delta(a, b), "n": len(a)})
            if v != "A0":
                c = vals(f"A0n{suf}", t, "450000", "obs_deliv")
                if len(a) >= 3 and len(c) >= 3:
                    tests.append({"cond": suf or "_64", "variant": v, "tenant": t, "vs": "A0",
                                  "p": mann_whitney(a, c), "delta": cliffs_delta(a, c), "n": len(a)})
    L.append("\\midrule")
L[-1] = "\\bottomrule"
L.append("\\end{tabular}")
open(os.path.join(TAB, "table_frame_size_tcp.tex"), "w").write("\n".join(L) + "\n")
for t_, ph in zip(tests, holm([t["p"] if isinstance(t["p"], float) else t["p"][1] for t in tests])):
    t_["p_holm"] = ph
    if not isinstance(t_["p"], float):
        t_["p"] = t_["p"][1]
with open(os.path.join(PROC, "rev2_tests.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(tests[0].keys()))
    w.writeheader()
    w.writerows(tests)
json.dump(S, open(os.path.join(PROC, "rev2_extra.json"), "w"), indent=1)
print("\n".join(L))
for t in tests:
    print(t)
