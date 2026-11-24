#!/usr/bin/env python3
"""
01_process_runs.py - obrada sirovih merenja: interferencija, CPU budzet, samoopterecenje
=======================================================================================

Ulaz: data/raw/index/{interference,cpu_budget,self_load}_runs.csv i za svako merenje (kolona run)
  data/raw/<path>/server/{cpu,ovs}.jsonl.gz i data/raw/<path>/generator/tenantN.json
Izlaz:
  results/processed/interference_runs.csv, interference_cells.csv, cpu_budget_runs.csv, self_load_runs.csv
Metrike posmatranog tenanta (interferencija): p50/p99 latencije, gubitak latency toka, isporuka na tier1
(pps instance ovs-N / poslato), CPU. Indeks izolacije I = medijana metrike pri P / medijana pri P=0,
u istoj varijanti i konfiguraciji; test P vs 0: Mann-Whitney (Holm), velicina efekta: Cliff-ov delta.

  python3 analysis/01_process_runs.py
"""
import csv
import json
import math
import os
import statistics as st
from datetime import datetime

import numpy as np

from stats import bootstrap_ci, cliffs_delta, holm, mann_whitney

from common import PROC as OUT, index_csv, server_file, gen_file, opentext
BG_PPS, LAT_PPS = 20000, 1000


def ts(s):
    return datetime.fromisoformat(s).timestamp()


def load_json(path):
    try:
        with open(path) as f:
            return json.loads(f.read().strip().splitlines()[-1])
    except (OSError, ValueError, IndexError):
        return None


def runs(csvname):
    p = index_csv(csvname)
    if not p:
        return []
    with open(p) as f:
        return [r for r in csv.DictReader(f) if r["status"] == "ok"]


def ovs_rates(name, t0, t1):
    """pps po instanci iz brojaca datapath-a (dpctl/show: hit + missed), medijana u prozoru [t0, t1]"""
    p = server_file(name, "ovs.jsonl")
    if not os.path.exists(p):
        return {}
    with opentext(p) as f:
        snaps = [json.loads(l) for l in f]
    res = {}
    for a, b in zip(snaps, snaps[1:]):
        if not (t0 <= b["ts"] <= t1):
            continue
        for i, eb in b["instances"].items():
            ea = a["instances"].get(i)
            if not ea or not ea.get("dp") or not eb.get("dp"):
                continue
            n = (eb["dp"]["hit"] + eb["dp"]["missed"]) - (ea["dp"]["hit"] + ea["dp"]["missed"])
            res.setdefault(i, []).append(n / (b["ts"] - a["ts"]))
    return {i: st.median(v) for i, v in res.items() if v}


def svc_rates(name, t0, t1):
    """pps primljeni na eth0 servisa (ovs.jsonl: svc_rx_pkts), medijana u prozoru [t0, t1]"""
    p = server_file(name, "ovs.jsonl")
    if not os.path.exists(p):
        return {}
    with opentext(p) as f:
        snaps = [json.loads(l) for l in f]
    res = {}
    for a, b in zip(snaps, snaps[1:]):
        if t0 <= b["ts"] <= t1 and a.get("svc_rx_pkts") and b.get("svc_rx_pkts"):
            for n, v in b["svc_rx_pkts"].items():
                if n in a["svc_rx_pkts"]:
                    res.setdefault(n, []).append((v - a["svc_rx_pkts"][n]) / (b["ts"] - a["ts"]))
    return {n: st.median(v) for n, v in res.items() if v}


def softnet_window(name, t0, t1):
    """po CPU-u: odbaceni paketi/s (backlog pun) i time_squeeze/s, iz /proc/net/softnet_stat
    snimaka; plus 'lost' (upcall nije isporucen) po OvS instanci. {} ako snimci nemaju softnet."""
    p = server_file(name, "ovs.jsonl")
    if not os.path.exists(p):
        return {}
    with opentext(p) as f:
        snaps = [json.loads(l) for l in f]
    w = [x for x in snaps if t0 <= x["ts"] <= t1 and x.get("softnet")]
    if len(w) < 2:
        return {}
    a, b = w[0], w[-1]
    dt = b["ts"] - a["ts"]
    drop = [(y[1] - x[1]) / dt for x, y in zip(a["softnet"], b["softnet"])]
    sq = [(y[2] - x[2]) / dt for x, y in zip(a["softnet"], b["softnet"])]
    res = {"drop_total": sum(drop), "squeeze_total": sum(sq),
           "drop_by_cpu": {i: round(v) for i, v in enumerate(drop) if v > 0.5},
           "squeeze_by_cpu": {i: round(v, 1) for i, v in enumerate(sq) if v > 0.05}}
    for i, eb in b["instances"].items():
        ea = a["instances"].get(i)
        if ea and ea.get("dp") and eb.get("dp"):
            res[f"{i}.lost"] = (eb["dp"]["lost"] - ea["dp"]["lost"]) / dt
    return res


def slo_fraction(j, limit_us=1000.0):
    """udeo latency paketa isporucenih u roku (RTT < limit_us) u odnosu na POSLATE (gubitak = kasno);
    korpe TRex histograma ispod 1 ms su 10/100 us, pa je granica 1 ms tacna"""
    h = j.get("histogram_us") or {}
    tx = j.get("lat_tx_pkts") or 0
    if not tx:
        return None
    ok = sum(int(v) for k, v in h.items() if float(k) + (10 if float(k) < 100 else 100) <= limit_us)
    return min(1.0, ok / tx)


def budget_window(name, t0, t1):
    """zatvaranje CPU budzeta (K1): softirq jezgra po CPU-u iz /proc/stat tikova i ukupno prolaza kroz
    datapath (zbir dpctl pps svih instanci); {} ako snimci nemaju cpu_ticks"""
    p = server_file(name, "ovs.jsonl")
    if not os.path.exists(p):
        return {}
    with opentext(p) as f:
        snaps = [json.loads(l) for l in f]
    w = [x for x in snaps if t0 <= x["ts"] <= t1 and x.get("cpu_ticks")]
    if len(w) < 2:
        return {}
    a, b = w[0], w[-1]
    dt = b["ts"] - a["ts"]
    hz = 100.0
    sirq = [(y[0] - x[0]) / hz / dt for x, y in zip(a["cpu_ticks"], b["cpu_ticks"])]
    passes = 0.0
    for i, eb in b["instances"].items():
        ea = a["instances"].get(i)
        if ea and ea.get("dp") and eb.get("dp"):
            passes += ((eb["dp"]["hit"] + eb["dp"]["missed"]) - (ea["dp"]["hit"] + ea["dp"]["missed"])) / dt
    tot = sum(sirq)
    busiest = max(range(len(sirq)), key=lambda i: sirq[i])
    return {"softirq_cores": tot, "softirq_busiest_cpu": busiest, "softirq_busiest_core": sirq[busiest],
            "dp_passes_pps": passes, "softirq_us_per_pass": tot * 1e6 / passes if passes else None}


def server_window(name, t0, t1):
    """medijane metrika servera u prozoru [t0, t1] (epoch s). pps po instanci iz OvS brojaca;
    eBPF CPU vrednost instance se odbacuje ako eBPF za nju nema paketa, a brojaci ih imaju."""
    res = _ebpf_window(name, t0, t1) or {}
    for i, pps in ovs_rates(name, t0, t1).items():
        if pps > 1000 and not res.get(f"{i}.pps"):
            for k in ("kernel_pct", "ns_per_pkt", "total_pct"):
                res[f"{i}.{k}"] = None
        res[f"{i}.pps_ebpf"] = res.get(f"{i}.pps")
        res[f"{i}.pps"] = pps
    return res or None


def _ebpf_window(name, t0, t1):
    rows = []
    p = server_file(name, "cpu.jsonl")
    if not os.path.exists(p):
        return None
    with opentext(p) as f:
        for line in f:
            r = json.loads(line)
            if r.get("event") == "metrics" and t0 <= ts(r["timestamp"]) <= t1:
                rows.append(r)
    if not rows:
        return None
    insts = set().union(*(r["instances"].keys() for r in rows))
    res = {"softirq_pct": st.median(r["system"]["softirq_pct"] for r in rows)}
    for i in insts:
        for k in ("pps", "kernel_pct", "user_pct", "ns_per_pkt", "total_pct"):
            vals = [r["instances"].get(i, {}).get(k) for r in rows]
            vals = [v for v in vals if v is not None]
            res[f"{i}.{k}"] = st.median(vals) if vals else None
    return res


def cell_stats(groups, metric, base_key):
    """za svaku celiju: medijana + bootstrap CI, I = med/med(base), MW p, Cliff delta vs base"""
    out = {}
    for key, vals in groups.items():
        base = groups.get(base_key(key))
        x = [v for v in vals if v is not None]
        med, lo, hi = bootstrap_ci(x)
        d = {"n": len(x), "med": med, "ci_lo": lo, "ci_hi": hi}
        if base is not None:
            b = [v for v in base if v is not None]
            bmed = st.median(b) if b else math.nan
            d["I"] = med / bmed if bmed else math.nan
            d["p"] = mann_whitney(x, b) if key != base_key(key) else math.nan
            d["delta"] = cliffs_delta(x, b) if key != base_key(key) else math.nan
        out[key] = d
    keys = [k for k in out if not math.isnan(out[k].get("p", math.nan))]
    for k, padj in zip(keys, holm([out[k]["p"] for k in keys])):
        out[k]["p_holm"] = padj
    return out


def interference():
    rows = []
    for r in runs("interference_runs.csv"):
        run, P = r["run"], int(r["load_pps"])
        t1j = load_json(gen_file(run, 1)) if P else None
        for t in (2, 3):
            j = load_json(gen_file(run, t))
            if not j:
                continue
            srv = server_window(run, j["t_start"] + 1, j["t_end"] - 1)
            l = j["lat_us"]
            # stvarno poslato (TRex port 0 posle zagrevanja), ne nominalno: pod opterecenjem generator
            # zbog deljenja jezgara salje manje od zadatog
            sent = j["port0"]["opackets"] / j["elapsed_s"] if j.get("port0") and j["elapsed_s"] else BG_PPS + LAT_PPS
            row = {"run": run, "variant": r["variant"], "cfg": r["cfg"], "load_pps": P, "rep": int(r["rep"]),
                   "tenant": t, "p50": l.get("p50"), "p99": l.get("p99"), "avg": l.get("avg"),
                   "max": l.get("max"), "jitter": l.get("jitter"), "lat_loss_pct": j["lat_loss_pct"],
                   "load_tx_pps": t1j["avg_tx_pps"] if t1j else 0.0, "obs_tx_pps": sent,
                   "slo_1ms": slo_fraction(j)}
            if srv:
                inst = f"ovs-{t}" if f"ovs-{t}.pps" in srv else "tier0"
                row.update({"obs_pps": srv.get(f"ovs-{t}.pps"),
                            "obs_deliv": (srv.get(f"ovs-{t}.pps") or 0) / sent if f"ovs-{t}.pps" in srv else None,
                            "load_tier1_pps": srv.get("ovs-1.pps"), "tier0_pps": srv.get("tier0.pps"),
                            "tier0_kernel_pct": srv.get("tier0.kernel_pct"),
                            "obs_kernel_pct": srv.get(f"{inst}.kernel_pct"),
                            "softirq_pct": srv.get("softirq_pct")})
                sn = softnet_window(run, j["t_start"] + 1, j["t_end"] - 1)
                if sn:
                    row.update({"softnet_drop_pps": sn["drop_total"], "softnet_squeeze_ps": sn["squeeze_total"],
                                "softnet_drop_by_cpu": json.dumps(sn["drop_by_cpu"]),
                                "softnet_squeeze_by_cpu": json.dumps(sn["squeeze_by_cpu"]),
                                "dp_lost_pps": sum(v for k, v in sn.items() if k.endswith(".lost"))})
                # isporuka: u A0/A1 nema tier1 instance, pa se koristi prijem na eth0 servisa
                # (samo pozadinski tok; latency paketi se reflektuju pre servisa)
                sv = svc_rates(run, j["t_start"] + 1, j["t_end"] - 1).get(f"svc{t}")
                row["obs_deliv_dp"] = row.get("obs_deliv")
                row["obs_deliv_svc"] = sv / max(1.0, sent - LAT_PPS) if sv is not None else None
                if row.get("obs_deliv") is None:
                    row["obs_deliv"] = row["obs_deliv_svc"]
                # stvarno ponudjeno opterecenje na serveru: tier0 vidi opterecujuci tok + 2 posmatrana
                # (BG + LAT) + reflektovane latency pakete na povratku (2 x LAT)
                if srv.get("tier0.pps") is not None:
                    row["offered_load_pps"] = max(0.0, srv["tier0.pps"] - 2 * (BG_PPS + LAT_PPS) - 2 * LAT_PPS)
            if t == 2:
                row.update({f"bud_{k}": v for k, v in budget_window(run, j["t_start"] + 1, j["t_end"] - 1).items()})
            rows.append(row)
    if not rows:
        return [], {}
    write(os.path.join(OUT, "interference_runs.csv"), rows)
    cells = []
    for metric in ("p50", "p99", "lat_loss_pct", "obs_deliv", "slo_1ms"):
        groups = {}
        for x in rows:
            groups.setdefault((x["variant"], x["cfg"], x["tenant"], x["load_pps"]), []).append(x.get(metric))
        cs = cell_stats(groups, metric, lambda k: (k[0], k[1], k[2], 0))
        for k, d in sorted(cs.items()):
            cells.append({"metric": metric, "variant": k[0], "cfg": k[1], "tenant": k[2], "load_pps": k[3], **d})
    write(os.path.join(OUT, "interference_cells.csv"), cells)
    return rows, cells


def r_float(x):
    return float(x) if float(x) else math.nan


def cpu_budget():
    """CPU budzet: jedan tok bez latency toka; CPU po paketu po sloju i isporuka na tier1 blize zasicenju"""
    rows = []
    for r in runs("cpu_budget_runs.csv"):
        j = load_json(gen_file(r["run"], 1))
        if not j:
            continue
        srv = server_window(r["run"], j["t_start"] + 1, j["t_end"] - 1)
        if not srv:
            continue
        row = {"run": r["run"], "variant": r["variant"], "pps": int(r["pps"]), "rep": int(r["rep"]),
               "tx_pps": j["avg_tx_pps"], "tier0_pps": srv.get("tier0.pps"), "tier1_pps": srv.get("ovs-1.pps"),
               "tier0_kernel_pct": srv.get("tier0.kernel_pct"), "tier1_kernel_pct": srv.get("ovs-1.kernel_pct"),
               "softirq_pct": srv.get("softirq_pct")}
        u = None
        if row["tier0_kernel_pct"] is not None and row["tier0_pps"]:
            u = row["tier0_kernel_pct"] / 100 * 1e6 / row["tier0_pps"]
            if row["tier1_pps"]:
                u = u + row["tier1_kernel_pct"] / 100 * 1e6 / row["tier1_pps"] if row["tier1_kernel_pct"] is not None else None
        row["us_per_pkt"] = u
        bw = budget_window(r["run"], j["t_start"] + 1, j["t_end"] - 1)
        row.update(bw)
        # eBPF pokrivenost: kernel_pct (svih instanci) / softirq jezgra
        k = (row["tier0_kernel_pct"] or 0) + (row["tier1_kernel_pct"] or 0)
        row["ebpf_coverage"] = k / 100 / bw["softirq_cores"] if bw.get("softirq_cores") else None
        # isporuka do servisa: tier1 (A2) ili prijem na eth0 servisa (A0/A1)
        sv = svc_rates(r["run"], j["t_start"] + 1, j["t_end"] - 1).get("svc1")
        row["deliv"] = (row["tier1_pps"] or sv or 0) / row["tx_pps"] if row["tx_pps"] else None
        rows.append(row)
    if rows:
        write(os.path.join(OUT, "cpu_budget_runs.csv"), rows)
    return rows


def self_load():
    """Samoopterecenje: opterecujuci tenant sam; njegova latencija, SLO i isporuka (prijem na svc1/tier1)"""
    rows = []
    for r in runs("self_load_runs.csv"):
        j = load_json(gen_file(r["run"], 1))
        if not j:
            continue
        srv = server_window(r["run"], j["t_start"] + 1, j["t_end"] - 1) or {}
        sent = j["port0"]["opackets"] / j["elapsed_s"] if j.get("port0") and j["elapsed_s"] else None
        sv = svc_rates(r["run"], j["t_start"] + 1, j["t_end"] - 1).get("svc1")
        t1 = srv.get("ovs-1.pps")
        l = j["lat_us"]
        row = {"run": r["run"], "variant": r["variant"], "cfg": r["cfg"], "load_pps": int(r["load_pps"]),
               "rep": int(r["rep"]), "tx_pps": sent, "p50": l.get("p50"), "p99": l.get("p99"),
               "lat_loss_pct": j["lat_loss_pct"], "slo_1ms": slo_fraction(j),
               "deliv": ((t1 if t1 is not None else (sv or 0) + 1000) / sent) if sent else None}
        row.update(budget_window(r["run"], j["t_start"] + 1, j["t_end"] - 1))
        rows.append(row)
    if rows:
        write(os.path.join(OUT, "self_load_runs.csv"), rows)
    return rows


def write(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: (round(v, 4) if isinstance(v, float) else v) for k, v in r.items()})


def main():
    r1, _ = interference()
    print(f"interferencija: {len(r1)} redova (tenant x merenje)")
    print(f"CPU budzet: {len(cpu_budget())} merenja")
    print(f"samoopterecenje: {len(self_load())} merenja")


if __name__ == "__main__":
    main()
