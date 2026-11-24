#!/usr/bin/env python3
"""
02_interference_tables.py - tabele i slike revizije (kampanja 18-19. 11. 2026, bpf firmware, prstenovi 4096,
fiksni coalescing; RPS kartice n = 0000, w = ffff). Ulaz: results/processed/*.csv
(posle 01_process_runs.py). Izlaz: results/tables/table_{2x2,mehanizam,cpu_budget,self_load}.tex, results/figures/overview_*.pdf
i results/processed/rev_summary.json (brojevi za tekst).

  python3 analysis/02_interference_tables.py
"""
import sys as _sys, os as _os; _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from common import PROC, TAB, FIG, gen_file
import csv
import json
import math
import os
import statistics as st

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from stats import bootstrap_ci, cliffs_delta, holm, mann_whitney  # noqa: E402

V = ["A0", "A1", "A2", "A3", "A4"]
CONF = [("n", "same", "uzak RPS, isti red"), ("n", "diff", "uzak RPS, razl. redovi"),
        ("w", "same", "širok RPS, isti red"), ("w", "diff", "širok RPS, razl. redovi")]
plt.rcParams.update({"font.size": 8, "axes.grid": True, "grid.alpha": 0.3})


def rd(n):
    with open(os.path.join(PROC, n)) as f:
        return list(csv.DictReader(f))


def fl(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def vals(rows, k, **kw):
    return [fl(r[k]) for r in rows if all(str(r[a]) == str(b) for a, b in kw.items()) and fl(r.get(k)) is not None]


def med(x):
    return st.median(x) if x else math.nan


def num(x, d=0):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "--"
    return f"{x:.{d}f}".replace(".", "{,}")


def tex(name, lines):
    os.makedirs(TAB, exist_ok=True)
    with open(os.path.join(TAB, name), "w") as f:
        f.write("% generisano: analysis/02_interference_tables.py\n" + "\n".join(lines) + "\n")


S = {}
intf = rd("interference_runs.csv")

# ---- 2x2 tabela pri najvecem opterecenju (450k cilj) ----
TOP = "450000"
L = [r"\begin{tabular}{@{}llrrrrrr@{}}", r"\toprule",
     r"Konfig. & Var. & \multicolumn{2}{c}{p50 [µs]} & \multicolumn{2}{c}{isporuka} & \multicolumn{2}{c}{u roku $\leq$1~ms} \\",
     r"\cmidrule(lr){3-4}\cmidrule(lr){5-6}\cmidrule(lr){7-8}", r" & & t2 & t3 & t2 & t3 & t2 & t3 \\", r"\midrule"]
pv, keys = [], []
for rps, cfg, cname in CONF:
    for v in V:
        lab = v + rps
        row = [cname if v == "A0" else "", v]
        for m, d in (("p50", 0), ("obs_deliv", 2), ("slo_1ms", 2)):
            for t in ("2", "3"):
                x = vals(intf, m, variant=lab, cfg=cfg, tenant=t, load_pps=TOP)
                S[f"{lab}_{cfg}_t{t}_{m}"] = med(x)
                S[f"{lab}_{cfg}_t{t}_{m}_base"] = med(vals(intf, m, variant=lab, cfg=cfg, tenant=t, load_pps="0"))
                row.append(num(med(x), d))
        L.append(" & ".join(row) + r" \\")
    L.append(r"\midrule")
L[-1] = r"\bottomrule"
L.append(r"\end{tabular}")
tex("table_2x2.tex", L)

# ---- ponudjeno opterecenje na serveru po cilju ----
for rps, cfg, _ in CONF:
    for v in ("A0", "A2", "A4"):
        for P in ("200000", "300000", "450000"):
            S[f"offered_{v}{rps}_{cfg}_{P}"] = med(vals(intf, "offered_load_pps", variant=v + rps, cfg=cfg, tenant="2", load_pps=P)) / 1e3

# ---- mehanizam: softnet odbacivanje po CPU-u (t2 redovi nose softnet) ----
L = [r"\begin{tabular}{@{}lllrrrl@{}}", r"\toprule",
     r"Konfig. & Var. & Cilj [kpps] & Odbačeno [kpps] & Najzauzetije jezgro [udeo] & Isporuka t2 & CPU \\", r"\midrule"]
for rps, cfg, cname in CONF:
    for v in ("A0", "A2", "A4"):
        for P in ("300000", "450000"):
            rr = [r for r in intf if r["variant"] == v + rps and r["cfg"] == cfg and r["tenant"] == "2" and r["load_pps"] == P]
            drop = med([fl(r["softnet_drop_pps"]) for r in rr if fl(r.get("softnet_drop_pps")) is not None])
            busy = med([fl(r["bud_softirq_busiest_core"]) for r in rr if fl(r.get("bud_softirq_busiest_core")) is not None])
            cpus = {}
            for r in rr:
                for c, x in json.loads(r.get("softnet_drop_by_cpu") or "{}").items():
                    cpus.setdefault(c, []).append(x)
            cl = ",".join(sorted(cpus, key=int)) or "--"
            S[f"drop_{v}{rps}_{cfg}_{P}"] = drop / 1e3 if not math.isnan(drop) else drop
            S[f"busy_{v}{rps}_{cfg}_{P}"] = busy
            L.append(f"{cname if v == 'A0' and P == '300000' else ''} & {v} & {int(P)//1000} & {num(drop/1e3, 1)} & "
                     f"{num(busy, 2)} & {num(med(vals(intf, 'obs_deliv', variant=v+rps, cfg=cfg, tenant='2', load_pps=P)), 2)} & {cl} \\\\")
    L.append(r"\midrule")
L[-1] = r"\bottomrule"
L.append(r"\end{tabular}")
tex("table_mehanizam.tex", L)

# ---- CPU budzet (uzak RPS) ----
budget = [r for r in rd("cpu_budget_runs.csv") if r["variant"].endswith("n")]
L = [r"\begin{tabular}{@{}rlrrrrr@{}}", r"\toprule",
     r"Cilj [kpps] & Var. & Ostv. [kpps] & eBPF [µs/pak.] & softirq [µs/pak.] & softirq [µs/prolaz] & pokrivenost eBPF \\",
     r"\midrule"]
for P in ("100000", "150000", "200000", "250000"):
    ref = None
    for v in ("A0", "A1", "A2"):
        rr = [r for r in budget if r["variant"] == v + "n" and r["pps"] == P]
        pk = [fl(r["softirq_cores"]) * 1e6 / fl(r["tier0_pps"]) for r in rr if fl(r.get("softirq_cores")) and fl(r.get("tier0_pps"))]
        S[f"bud_{v}_{P}_sirq_us_pkt"] = med(pk)
        S[f"bud_{v}_{P}_ebpf_us_pkt"] = med([fl(r["us_per_pkt"]) for r in rr if fl(r.get("us_per_pkt"))])
        S[f"bud_{v}_{P}_cov"] = med([fl(r["ebpf_coverage"]) for r in rr if fl(r.get("ebpf_coverage"))])
        S[f"bud_{v}_{P}_pass"] = med([fl(r["softirq_us_per_pass"]) for r in rr if fl(r.get("softirq_us_per_pass"))])
        S[f"bud_{v}_{P}_ach"] = med([fl(r["tier0_pps"]) for r in rr if fl(r.get("tier0_pps"))]) / 1e3
        if v == "A0":
            ref = pk
        else:
            S[f"bud_{v}_{P}_p_vs_A0"] = mann_whitney(pk, ref)
            S[f"bud_{v}_{P}_delta_vs_A0"] = cliffs_delta(pk, ref)
        L.append(f"{int(P)//1000} & {v} & {num(S[f'bud_{v}_{P}_ach'])} & {num(S[f'bud_{v}_{P}_ebpf_us_pkt'], 2)} & "
                 f"{num(S[f'bud_{v}_{P}_sirq_us_pkt'], 2)} & {num(S[f'bud_{v}_{P}_pass'], 2)} & {num(S[f'bud_{v}_{P}_cov'], 2)} \\\\")
    L.append(r"\midrule")
L[-1] = r"\bottomrule"
L.append(r"\end{tabular}")
tex("table_cpu_budget.tex", L)
ratios = [S[f"bud_A2_{P}_sirq_us_pkt"] / S[f"bud_A0_{P}_sirq_us_pkt"] for P in ("100000", "150000", "200000", "250000")]
S["hier_overhead_softirq_pct"] = [round((x - 1) * 100) for x in ratios]
eb = [S[f"bud_A2_{P}_ebpf_us_pkt"] / S[f"bud_A0_{P}_ebpf_us_pkt"] for P in ("100000", "150000", "200000", "250000")]
S["hier_overhead_ebpf_pct"] = [round((x - 1) * 100) for x in eb]
S["ebpf_cov_range"] = [min(S[k] for k in S if k.endswith("_cov")), max(S[k] for k in S if k.endswith("_cov"))]

# ---- samoopterecenje ----
selfl = rd("self_load_runs.csv")
L = [r"\begin{tabular}{@{}rlrrrr@{}}", r"\toprule",
     r"Cilj [kpps] & Var. & Ostv. [kpps] & p50 [µs] & u roku $\leq$1~ms & isporuka \\", r"\midrule"]
for P in ("50000", "100000", "150000", "200000", "300000", "450000"):
    for v in ("A0", "A2", "A4"):
        rr = [r for r in selfl if r["variant"] == v + "n" and r["load_pps"] == P]
        for m in ("tx_pps", "p50", "slo_1ms", "deliv"):
            S[f"self_{v}_{P}_{m}"] = med([fl(r[m]) for r in rr if fl(r.get(m)) is not None])
        L.append(f"{int(P)//1000} & {v} & {num(S[f'self_{v}_{P}_tx_pps']/1e3)} & {num(S[f'self_{v}_{P}_p50'])} & "
                 f"{num(S[f'self_{v}_{P}_slo_1ms'], 2)} & {num(S[f'self_{v}_{P}_deliv'], 2)} \\\\")
    L.append(r"\midrule")
L[-1] = r"\bottomrule"
L.append(r"\end{tabular}")
tex("table_self_load.tex", L)

# ---- statistika: A2 i A4 prema A0 pri najvecem opterecenju (isporuka i p50, t2) ----
tests = []
for rps, cfg, _ in CONF:
    for v in ("A1", "A2", "A3", "A4"):
        for m in ("obs_deliv", "p50"):
            for t in ("2", "3"):
                x = vals(intf, m, variant=v + rps, cfg=cfg, tenant=t, load_pps=TOP)
                y = vals(intf, m, variant="A0" + rps, cfg=cfg, tenant=t, load_pps=TOP)
                tests.append({"rps": rps, "cfg": cfg, "variant": v, "metric": m, "tenant": t,
                              "p": mann_whitney(x, y), "delta": cliffs_delta(x, y)})
for t_, ph in zip(tests, holm([t["p"] for t in tests])):
    t_["p_holm"] = ph
with open(os.path.join(PROC, "rev_tests_vs_A0.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(tests[0].keys()))
    w.writeheader(); w.writerows(tests)

# ---- slike: mreza 3 konfiguracije x 5 varijanti ----
def grid(metric, ylabel, fname, logy=False):
    fig, axs = plt.subplots(len(CONF), 5, figsize=(7.2, 1.75 * len(CONF)), sharex=True, sharey=True)
    for i, (rps, cfg, cname) in enumerate(CONF):
        for j, v in enumerate(V):
            ax = axs[i][j]
            for t, col in (("2", "#003f5c"), ("3", "#ef5675")):
                pts = []
                for P in ("0", "50000", "100000", "150000", "200000", "300000", "450000"):
                    o = vals(intf, "offered_load_pps", variant=v + rps, cfg=cfg, tenant=t, load_pps=P)
                    y = vals(intf, metric, variant=v + rps, cfg=cfg, tenant=t, load_pps=P)
                    if y:
                        c = bootstrap_ci(y)
                        pts.append((med(o) / 1e3 if o else int(P) / 1e3, c))
                if pts:
                    ax.plot([p[0] for p in pts], [p[1][0] for p in pts], marker="o", ms=2, lw=1, color=col, label=f"tenant {t}")
                    ax.fill_between([p[0] for p in pts], [p[1][1] for p in pts], [p[1][2] for p in pts], color=col, alpha=0.15)
            if logy:
                ax.set_yscale("log")
            if i == 0:
                ax.set_title(v)
            if j == 0:
                ax.set_ylabel(f"{cname}\n{ylabel}", fontsize=7)
            if i == len(CONF) - 1:
                ax.set_xlabel("opt. [kpps]", fontsize=7)
            ax.tick_params(labelsize=6)
    axs[0][-1].legend(fontsize=6)
    fig.tight_layout()
    os.makedirs(FIG, exist_ok=True)
    fig.savefig(os.path.join(FIG, fname), bbox_inches="tight")
    plt.close(fig)


grid("p50", "p50 [µs]", "overview_p50.pdf", logy=True)
grid("obs_deliv", "isporuka", "overview_isporuka.pdf")

with open(os.path.join(PROC, "rev_summary.json"), "w") as f:
    json.dump({k: (None if isinstance(v, float) and math.isnan(v) else v) for k, v in S.items()}, f, indent=1)
print("tabele i slike revizije napravljene")
for k in ("hier_overhead_softirq_pct", "hier_overhead_ebpf_pct", "ebpf_cov_range"):
    print(k, S[k])
