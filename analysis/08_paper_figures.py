#!/usr/bin/env python3
"""Sazeti grafici za sekciju 5 (kratka verzija).
Izlaz: results/figures/k5_*.pdf
"""
import csv, json, os, statistics as st
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
import sys as _sys; _sys.path.insert(0, HERE)
from common import PROC, TAB, FIG, gen_file
INTF = list(csv.DictReader(open(os.path.join(PROC, "interference_runs.csv"))))
BUDGET = list(csv.DictReader(open(os.path.join(PROC, "cpu_budget_runs.csv"))))
MOD = {r["var"]: r for r in csv.DictReader(open(os.path.join(PROC, "rev_model.csv")))}
RHO = json.load(open(os.path.join(PROC, "rev_interferencija.json")))
V = ["A0", "A1", "A2", "A3", "A4"]
COL = {"A0": "#1b9e77", "A1": "#66a61e", "A2": "#d95f02", "A3": "#e7298a", "A4": "#7570b3"}
plt.rcParams.update({"font.size": 8, "axes.spines.top": False, "axes.spines.right": False})


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None


def intf(var, cfg, P, t, m):
    return med([f(r[m]) for r in INTF if r["variant"] == var and r["cfg"] == cfg and r["load_pps"] == P and r["tenant"] == t])


def worst(var, cfg, P="450000"):
    d = [intf(var, cfg, P, t, "obs_deliv") for t in ("2", "3")]
    d = [x for x in d if x is not None]
    return min(d) if d else np.nan


# --- K1: toplotna mapa isporuke, 4 celije x 5 varijanti ---
CELLS = [("n", "same", "uzak RPS · isti red\n(deljeno jezgro)"), ("n", "diff", "uzak RPS · razl. redovi\n(razdvojena jezgra)"),
         ("w", "same", "širok RPS · isti red"), ("w", "diff", "širok RPS · razl. redovi")]
M = np.array([[min(1.0, worst(v + r, c)) for v in V] for r, c, _ in CELLS])
fig, ax = plt.subplots(figsize=(5.6, 2.4))
im = ax.imshow(M, cmap="RdYlGn", vmin=0.3, vmax=1.0, aspect="auto")
for i in range(M.shape[0]):
    for j in range(M.shape[1]):
        ax.text(j, i, f"{M[i, j] * 100:.0f}%", ha="center", va="center", fontsize=9,
                color="black" if M[i, j] > 0.45 else "white", fontweight="bold")
ax.set_xticks(range(len(V)))
ax.set_xticklabels(["A0\nbeslojni", "A1\nbridge/ten.", "A2\nhijerarhija", "A3\n+cpuset", "A4\n+RPS/ten."])
ax.set_yticks(range(len(CELLS)))
ax.set_yticklabels([c[2] for c in CELLS], fontsize=7)
ax.tick_params(length=0)
for s in ax.spines.values():
    s.set_visible(False)
cb = fig.colorbar(im, ax=ax, fraction=0.04, pad=0.02)
cb.set_label("isporuka", fontsize=7)
cb.ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0, decimals=0))
fig.tight_layout()
fig.savefig(os.path.join(FIG, "k5_toplotna_mapa.pdf"))
plt.close(fig)

# --- K2: isporuka i p50 prema opterecenju jezgra, deljeno jezgro, A0/A2/A4 ---
fig, axs = plt.subplots(1, 2, figsize=(6.6, 2.5))
for v in ("A0", "A2", "A4"):
    xs, d, p = [], [], []
    for P in ("0", "50000", "100000", "150000", "200000", "300000", "450000"):
        core = intf(v + "n", "same", P, "2", "tier0_pps")
        if core is None:
            continue
        xs.append(core / 1e3)
        d.append(min(worst(v + "n", "same", P), 1.05))
        p.append(max(intf(v + "n", "same", P, t, "p50") for t in ("2", "3")) / 1e3)
    axs[0].plot(xs, d, marker="o", ms=3.5, lw=1.6, color=COL[v], label=v)
    axs[1].plot(xs, p, marker="o", ms=3.5, lw=1.6, color=COL[v], label=v)
for v, ls in (("A0", ":"), ("A2", "--")):
    lo, hi = float(MOD[v]["knee_lo"]), float(MOD[v]["knee_hi"])
    axs[0].axvspan(lo, hi, color=COL[v], alpha=0.12)
    axs[0].text((lo + hi) / 2, 0.36, f"tačka zasićenja {v}", ha="center", fontsize=6.5, color=COL[v], rotation=90)
axs[0].set_ylim(0.3, 1.1)
axs[0].set_xlabel("opterećenje deljenog jezgra [kpps]")
axs[0].set_ylabel("isporuka (lošiji tenant)")
axs[0].yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0, decimals=0))
axs[0].legend(fontsize=7, loc="lower left")
axs[1].set_yscale("log")
axs[1].set_xlabel("opterećenje deljenog jezgra [kpps]")
axs[1].set_ylabel("p50 RTT [ms]")
axs[1].axhline(1.0, color="grey", lw=0.6, ls="--")
axs[1].text(axs[1].get_xlim()[0] if False else 45, 1.15, "1 ms", fontsize=6.5, color="grey")
fig.tight_layout()
fig.savefig(os.path.join(FIG, "k5_deljeno_jezgro.pdf"))
plt.close(fig)

# --- K3: okviri i TCP pri 450 kpps (deljeno jezgro) ---
COND = [("", "UDP 64 B"), ("_f512", "UDP 512 B"), ("_f1400", "UDP 1400 B"), ("_tcp", "TCP 64 B")]
fig, ax = plt.subplots(figsize=(3.3, 2.4))
w = 0.26
for k, v in enumerate(("A0", "A2", "A4")):
    ys = [min(worst(f"{v}n{s}", "same"), 1.0) for s, _ in COND]
    ax.bar([i + (k - 1) * w for i in range(len(COND))], ys, w, color=COL[v], label=v)
ax.set_xticks(range(len(COND)))
ax.set_xticklabels([c[1] for c in COND], fontsize=7)
ax.set_ylabel("isporuka pri 450 kpps")
ax.set_ylim(0, 1.1)
ax.set_yticks([0, 0.2, 0.4, 0.6, 0.8, 1.0])
ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0, decimals=0))
ax.legend(fontsize=7, ncol=3, loc="upper center", bbox_to_anchor=(0.5, 1.18), frameon=False)
fig.tight_layout()
fig.savefig(os.path.join(FIG, "k5_okviri_tcp.pdf"))
plt.close(fig)

# --- K4: zakonitost rho i cena hijerarhije ---
fig, axs = plt.subplots(1, 2, figsize=(6.6, 2.4))
for v in ("A0", "A1", "A2", "A3"):
    pts = [(r["rho"], r["meas"]) for r in RHO["rows"] if r["var"] == v]
    axs[0].scatter([p[0] for p in pts], [p[1] for p in pts], s=14, color=COL[v], label=v, zorder=3)
xs = np.linspace(0.2, 1.6, 200)
axs[0].plot(xs, np.minimum(1, 1 / xs), color="k", lw=1, label="min(1, 1/ρ)")
axs[0].axvline(1, color="grey", lw=0.6, ls="--")
axs[0].set_xlabel("ρ = Σλ / λmax")
axs[0].set_ylabel("isporuka (normalizovana)")
axs[0].yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0, decimals=0))
axs[0].legend(fontsize=6.5, loc="lower left")
from matplotlib.patches import Patch
vals = {}
for v in ("A0", "A2"):
    rr = [r for r in BUDGET if r["variant"] == v + "n"]
    vals[v] = (med([f(r["us_per_pkt"]) for r in rr]),
               med([f(r["softirq_cores"]) * 1e6 / f(r["tier0_pps"]) for r in rr if f(r["softirq_cores"]) and f(r["tier0_pps"])]))
for k, v in enumerate(("A0", "A2")):
    e, sq = vals[v]
    axs[1].bar(k - 0.19, e, 0.36, color=COL[v], alpha=0.45, hatch="///", edgecolor="k", lw=0.4)
    axs[1].bar(k + 0.19, sq, 0.36, color=COL[v], edgecolor="k", lw=0.4)
for k, (idx, dy) in enumerate(((0, 0.15), (1, 0.15))):
    a0, a2 = vals["A0"][idx], vals["A2"][idx]
    axs[1].text(1 + (-0.19 if idx == 0 else 0.19), a2 + dy, f"+{(a2 / a0 - 1) * 100:.0f}%", ha="center", fontsize=7)
axs[1].set_xticks(range(2))
axs[1].set_xticklabels(["A0 beslojni", "A2 hijerarhija"])
axs[1].set_ylabel("µs po paketu")
axs[1].set_ylim(0, max(vals["A2"]) * 1.45)
axs[1].legend(handles=[Patch(facecolor="white", hatch="///", edgecolor="k", label="eBPF: vreme u OVS-u"),
                       Patch(facecolor="grey", edgecolor="k", label="softirq: ukupno vreme")],
              fontsize=6.5, loc="upper left", frameon=False)
fig.tight_layout()
fig.savefig(os.path.join(FIG, "k5_zakon_cena.pdf"))
plt.close(fig)
print("ok")
