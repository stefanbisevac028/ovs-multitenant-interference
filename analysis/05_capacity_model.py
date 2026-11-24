#!/usr/bin/env python3
"""Validacija modela kapaciteta jezgra (revizija): lambda_max ~ 1/(N*c_prolaz + c0).

Predvidjanje: iz budzeta CPU-a (softirq us/paketu, uzak RPS, jedan tok) -> 1/c_paket, kao opseg preko
intenziteta merenja CPU budzeta (najveci intenzitet = najmanji trosak zbog NAPI grupisanja). A3 nema merenje CPU budzeta: pretpostavka
c(A3) = c(A2) (cpuset ne menja softirq put). A1 iz sopstvenog merenja CPU budzeta.
Nezavisna procena: opterecenje jezgra / udeo zauzetosti najzauzetijeg jezgra, u poslednjoj tacki merenja interferencije
bez odbacivanja i sa zauzetoscu < 0,95.
Izmereno: tacka zasicenja u merenju interferencije (uzak RPS, isti red; sve na istom jezgru) = interval opterecenja jezgra
(tier0 pps, svi tokovi) izmedju poslednje tacke bez gubitka i prve tacke sa gubitkom
(isporuka bilo kog posmatranog < osnovna linija - 0,10; prag veci od rasipanja
isporuke u osnovnoj liniji i od malog pada u A4).
Izlaz: results/processed/rev_model.csv, results/tables/table_capacity_model.tex
"""
import csv, os, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
import sys as _sys; _sys.path.insert(0, HERE)
from common import PROC, TAB, FIG, gen_file
INTF = list(csv.DictReader(open(os.path.join(PROC, "interference_runs.csv"))))
BUDGET = list(csv.DictReader(open(os.path.join(PROC, "cpu_budget_runs.csv"))))
TH = 0.10
LOADS = ["0", "50000", "100000", "150000", "200000", "300000", "450000"]


def med(xs):
    xs = [float(x) for x in xs if x not in ("", None)]
    return st.median(xs) if xs else None


def budget(v):
    """medijana softirq us/paketu po ciljnom intenzitetu (CPU budzet)"""
    out = []
    for P in sorted({r["pps"] for r in BUDGET}, key=float):
        m = med([float(r["softirq_cores"]) * 1e6 / float(r["tier0_pps"]) for r in BUDGET
                 if r["variant"] == v + "n" and r["pps"] == P and r["softirq_cores"] and r["tier0_pps"]])
        if m:
            out.append(m)
    return out


def intf_points(v, cfg="same"):
    pts = []
    for P in LOADS:
        rr = [r for r in INTF if r["variant"] == v + "n" and r["cfg"] == cfg and r["load_pps"] == P]
        t2 = [r for r in rr if r["tenant"] == "2"]
        pts.append(dict(P=int(P), core=med([r["tier0_pps"] for r in t2]),
                        d2=med([r["obs_deliv"] for r in t2]),
                        d3=med([r["obs_deliv"] for r in rr if r["tenant"] == "3"]),
                        busy=med([r["bud_softirq_busiest_core"] for r in t2]),
                        drop=med([r["softnet_drop_pps"] for r in t2]) or 0.0))
    return pts


rows = []
for v, N, src in [("A0", 1, "A0"), ("A1", 1, "A1"), ("A2", 2, "A2"), ("A3", 2, "A2"), ("A4", 1, None)]:
    c = budget(src) if src else []
    pred = (1e6 / max(c) / 1e3, 1e6 / min(c) / 1e3) if c else (None, None)
    pts = intf_points(v)
    b2, b3 = pts[0]["d2"], pts[0]["d3"]
    ok = [p for p in pts[1:] if p["d2"] >= b2 - TH and p["d3"] >= b3 - TH]
    bad = [p for p in pts[1:] if not (p["d2"] >= b2 - TH and p["d3"] >= b3 - TH)]
    last_ok = max((p["core"] for p in ok), default=None)
    first_bad = min((p["core"] for p in bad), default=None)
    util = [p for p in pts[1:] if p["drop"] == 0 and p["busy"] and p["busy"] < 0.95]
    u = util[-1] if util else None
    cap_util = u["core"] / u["busy"] / 1e3 if u else None
    pm = (pred[0] + pred[1]) / 2 if pred[0] else None
    km = (last_ok + first_bad) / 2 / 1e3 if (last_ok and first_bad) else None
    dev = 100 * (pm - km) / km if (pm and km) else None
    rows.append(dict(var=v, N=N, dev_pct=dev, c_min=min(c) if c else None, c_max=max(c) if c else None,
                     pred_lo=pred[0], pred_hi=pred[1], cap_util=cap_util,
                     knee_lo=last_ok / 1e3 if last_ok else None,
                     knee_hi=first_bad / 1e3 if first_bad else None,
                     budget_src=src or "--"))

with open(os.path.join(PROC, "rev_model.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]))
    w.writeheader()
    w.writerows(rows)


def n(x, d=0):
    return "--" if x is None else (f"{x:.{d}f}").replace(".", "{,}")


L = ["% generisano: analysis/05_capacity_model.py", "\\begin{tabular}{@{}lccccc@{}}", "\\toprule",
     "Var. & $N_{\\text{prolaza}}$ & \\makecell{Predviđeno iz budžeta\\\\$1/c_{\\text{paket}}$ [kpps]} & "
     "\\makecell{Iz zauzetosti jezgra\\\\{}[kpps]} & \\makecell{Izmerena tačka\\\\zasićenja [kpps]} & \\makecell{Odstupanje\\\\predviđanja} \\\\", "\\midrule"]
for r in rows:
    knee = (f"{n(r['knee_lo'])}--{n(r['knee_hi'])}" if r["knee_hi"] else f"$>${n(r['knee_lo'])}")
    pred = f"{n(r['pred_lo'])}--{n(r['pred_hi'])}" if r["pred_lo"] else "--"
    if r["var"] == "A3":
        pred += "$^{a}$"
    dv = "--" if r["dev_pct"] is None else (f"{r['dev_pct']:+.1f}".replace(".", "{,}") + "\\%")
    L.append(f"{r['var']} & {r['N']} & {pred} & {n(r['cap_util'])} & {knee} & {dv} \\\\")
devs = [abs(r["dev_pct"]) for r in rows if r["dev_pct"] is not None]
mae = sum(devs) / len(devs)
L += ["\\midrule", f"\\multicolumn{{5}}{{@{{}}l}}{{Srednja apsolutna greška predviđanja}} & {mae:.1f}\\%".replace(".", "{,}", 1) + " \\\\",
      "\\bottomrule", "\\end{tabular}"]
print("MAE", round(mae, 2))
open(os.path.join(TAB, "table_capacity_model.tex"), "w").write("\n".join(L) + "\n")
for r in rows:
    print(r)
