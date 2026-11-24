#!/usr/bin/env python3
"""Zakonitosti interferencije (P2/P3) na merenjima interferencije (uzak RPS, isti red = deljeno jezgro).

rho = sum(lambda_i) / lambda_max: dolazni intenzitet na deljeno jezgro (TX opterecujuceg + TX oba posmatrana
+ 2 x 1 kpps reflektovanih latency paketa) podeljen kapacitetom jezgra predvidjenim iz CPU budzeta
(sredina opsega iz rev_model.csv). Predvidjena isporuka = min(1, 1/rho); izmerena = isporuka posmatranih
normalizovana osnovnom linijom (P=0) iste varijante.
Dinamika: medijana prosecne latencije po sekundi (TRex serija, posle 2 s zagrevanja) u prvoj sekundi
prema ostatku merenja; vreme punjenja backlog-a Q/(r0 - r1) iz brojaca.
Izlaz: results/tables/table_rho.tex, results/processed/rev_interferencija.json
"""
import csv, json, os, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
import sys as _sys; _sys.path.insert(0, HERE)
from common import PROC, TAB, FIG, gen_file
R = list(csv.DictReader(open(os.path.join(PROC, "interference_runs.csv"))))
M = {r["var"]: r for r in csv.DictReader(open(os.path.join(PROC, "rev_model.csv")))}
LOADS = ["0", "50000", "100000", "150000", "200000", "300000", "450000"]
Q = 100000          # net.core.netdev_max_backlog
RING = 4096         # prsten prijema kartice


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def num(x, d=2):
    return "--" if x is None else f"{x:.{d}f}".replace(".", "{,}")


out, rows = {}, []
for v in ("A0", "A1", "A2", "A3"):
    lmax = (float(M[v]["pred_lo"]) + float(M[v]["pred_hi"])) / 2 * 1e3
    base = st.median([f(r["obs_deliv"]) for r in R if r["variant"] == v + "n" and r["cfg"] == "same"
                      and r["load_pps"] == "0" and f(r["obs_deliv"])])
    for P in LOADS:
        rr = [r for r in R if r["variant"] == v + "n" and r["cfg"] == "same" and r["load_pps"] == P]
        lam = []
        for rep in sorted({r["rep"] for r in rr}):
            x = [r for r in rr if r["rep"] == rep]
            lam.append((f(x[0]["load_tx_pps"]) or 0) + sum(f(y["obs_tx_pps"]) or 0 for y in x) + 2000)
        L = st.median(lam)
        rho = L / lmax
        meas = st.median([f(r["obs_deliv"]) for r in rr if f(r["obs_deliv"])]) / base
        rows.append(dict(var=v, P=int(P), lam=L, rho=rho, pred=min(1.0, 1 / rho), meas=meas))

err = {}
for grp, vs in (("beslojni", ("A0", "A1")), ("hijerarhija", ("A2", "A3"))):
    e_all = [abs(r["pred"] - r["meas"]) for r in rows if r["var"] in vs]
    e_sat = [r["pred"] - r["meas"] for r in rows if r["var"] in vs and r["rho"] > 1]
    err[grp] = dict(mae_all=st.mean(e_all), max_all=max(e_all), bias_sat=st.mean(e_sat) if e_sat else None)
out["rho_err"] = err

# dinamika: prva sekunda serije prema ostatku (A2, P=450)
dyn = {}
for v in ("A0", "A2"):
    first, rest = [], []
    for rep in range(1, 11):
        p = gen_file(f"interference_2x2/rps-narrow_queue-same/{v}/p450k_r{rep:02d}", 2)
        if not os.path.exists(p):
            continue
        s = [x["avg_us"] for x in json.load(open(p)).get("series", []) if x.get("avg_us")]
        if len(s) > 3:
            first.append(s[0])
            rest.append(st.median(s[1:]))
    dyn[v] = dict(first_ms=st.median(first) / 1e3, rest_ms=st.median(rest) / 1e3, n=len(first))
# brojaci u A2, P=450: r0 = tier0, r1 = tier0 - odbaceno u backlog-u
rr = [r for r in R if r["variant"] == "A2n" and r["cfg"] == "same" and r["load_pps"] == "450000" and r["tenant"] == "2"]
r0 = st.median([f(r["tier0_pps"]) for r in rr])
drop = st.median([f(r["softnet_drop_pps"]) for r in rr])
r1 = r0 - drop
dyn["A2_r0"], dyn["A2_r1"], dyn["A2_fill_s"] = r0, r1, Q / (r0 - r1)
dyn["A2_backlog_bound_s"] = Q / r1
r0a = st.median([f(r["tier0_pps"]) for r in R if r["variant"] == "A0n" and r["cfg"] == "same"
                 and r["load_pps"] == "450000" and r["tenant"] == "2"])
dyn["A0_ring_bound_ms"] = RING / r0a * 1e3
out["dyn"] = dyn

L = ["% generisano: analysis/06_interference_law.py", "\\begin{tabular}{@{}lrrrrr@{}}", "\\toprule",
     "Var. & Cilj [kpps] & $\\sum\\lambda_i$ [kpps] & $\\rho$ & \\makecell{Predviđena\\\\isporuka $\\min(1,1/\\rho)$} & "
     "\\makecell{Izmerena\\\\isporuka} \\\\", "\\midrule"]
for v in ("A0", "A2"):
    for r in rows:
        if r["var"] == v and r["P"] in (150000, 200000, 300000, 450000):
            L.append(f"{v} & {r['P'] // 1000} & {num(r['lam'] / 1e3, 0)} & {num(r['rho'])} & {num(r['pred'])} & {num(r['meas'])} \\\\")
    L.append("\\midrule")
L[-1] = "\\bottomrule"
L.append("\\end{tabular}")
open(os.path.join(TAB, "table_rho.tex"), "w").write("\n".join(L) + "\n")
json.dump(dict(out, rows=rows), open(os.path.join(PROC, "rev_interferencija.json"), "w"), indent=1)
print(json.dumps(out, indent=1))
