#!/usr/bin/env python3
"""
trex_latency.py - merenje latencije (RTT) iz jednog TRex kontejnera, rezultat kao jedan JSON red
================================================================================================

Latency tok je UDP tok (dst = servis tenanta, port --lat-port, UDP checksum 0) sa TRex
flow-latency potpisom. Na serveru ga reflektor (server-lab/ns-ovs-isolation/scripts/lat_reflect.sh,
OpenFlow pravilo na bridge-u ispred servisa) vraca na isti port TRex-a sa nepromenjenim payload-om
i IP ID-om, pa TRex paket racuna kao primljen paket svog toka (pg_id). Meri se RTT kroz OvS putanju.
Bez reflektora nema primljenih paketa (loss 100%).

Prvih --warmup sekundi (2 s) saobracaj ide, ali se statistika zatim brise, pa se prelazni period
ne racuna. Opciono uz latency tok ide i pozadinski UDP tok zadatog protoka (isto kao trex_bw.py), sa istog
porta, jer jedan TRex kontejner ima jedan port (port 0 = eth1).

Percentili se racunaju iz TRex histograma (korpe u us: 10, 20, ..., 90, 100, 200, ...) linearnom
interpolacijom unutar korpe; rezolucija je sirina korpe. Min, max, prosek i dzhiter su TRex-ovi.

Pokretanje sa traffic-generator-a (skripta ide preko stdin-a, ne kopira se u kontejner):
  ./run_trex.sh lat 1 --duration 30 --lat-pps 1000
ili direktno:
  sudo docker exec -i trex1 python3 - --src 10.10.10.11 --dst 10.10.10.101 < trex_latency.py
"""
import argparse
import json
import math
import sys
import time

sys.path.insert(0, "/opt/trex/automation/trex_control_plane/interactive")
from trex.stl.api import (STLClient, STLStream, STLPktBuilder, STLTXCont, STLFlowLatencyStats,  # noqa: E402
                          Ether, IP, UDP)

PERCENTILES = (50, 90, 99, 99.9)


def args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="IP TRex-a (eth1)")
    ap.add_argument("--dst", required=True, help="IP servisa tenanta")
    ap.add_argument("--duration", type=float, default=30, help="trajanje saobracaja u s (30)")
    ap.add_argument("--lat-pps", type=float, default=1000, help="brzina latency toka (1000 pps)")
    ap.add_argument("--lat-frame", type=int, default=128, help="velicina latency okvira sa FCS-om (128 B)")
    ap.add_argument("--lat-port", type=int, default=7, help="UDP dst port latency toka (7, = LAT_PORT na serveru)")
    ap.add_argument("--lat-sport", type=int, default=1026, help="UDP src port latency toka (bira RSS red)")
    ap.add_argument("--pg-id", type=int, default=7, help="TRex packet group id (7)")
    ap.add_argument("--bg-mbps", type=float, default=0, help="pozadinski UDP tok u Mbps, L2 (0 = bez)")
    ap.add_argument("--bg-frame", type=int, default=1400, help="velicina pozadinskog okvira (1400 B)")
    ap.add_argument("--bg-sport", type=int, default=1025, help="UDP src port pozadinskog toka (bira RSS red)")
    ap.add_argument("--bg-dport", type=int, default=5001, help="UDP dst port pozadinskog toka (5001)")
    ap.add_argument("--warmup", type=float, default=2.0,
                    help="zagrevanje u s: saobracaj ide, pa se statistika brise pre merenja (2 s)")
    ap.add_argument("--sample", type=float, default=1.0, help="period uzorkovanja vremenske serije (1 s)")
    ap.add_argument("--label", default="", help="proizvoljna oznaka koja se upisuje u rezultat")
    ap.add_argument("--server", default="localhost")
    ap.add_argument("--sync-port", type=int, default=4501)
    return ap.parse_args()


def padded(base, frame):
    pad = frame - 4 - len(base)                       # TRex dodaje 4 B FCS
    return base / ("x" * max(0, pad))


def pg_stats(c, pg):
    s = c.get_pgid_stats([pg])
    lat = s.get("latency", {}).get(pg, {})
    fs = s.get("flow_stats", {}).get(pg, {})
    return lat, fs


def total(fs, key):
    v = fs.get(key, {})
    if isinstance(v, dict):
        return v.get("total", sum(x for x in v.values() if isinstance(x, (int, float))))
    return v


def bucket_upper(k):
    return 10.0 if k <= 0 else k + 10 ** math.floor(math.log10(k))


def hist_percentiles(hist):
    items = sorted((float(k), int(v)) for k, v in hist.items() if int(v) > 0)
    n = sum(v for _, v in items)
    res = {}
    if not n:
        return res
    for q in PERCENTILES:
        target, cum = q / 100.0 * n, 0
        for k, v in items:
            if cum + v >= target:
                frac = (target - cum) / v
                res[f"p{q:g}".replace(".", "_")] = round(k + frac * (bucket_upper(k) - k), 1)
                break
            cum += v
    return res


def read_mac(ifname="eth1"):
    try:
        with open(f"/sys/class/net/{ifname}/address") as f:
            return f.read().strip()
    except OSError:
        return None


def main():
    a = args()
    base = Ether() / IP(src=a.src, dst=a.dst) / UDP(sport=a.lat_sport, dport=a.lat_port, chksum=0)
    if a.lat_frame - 4 - len(base) < 16:
        sys.exit("--lat-frame je premali za TRex latency potpis")
    streams = [STLStream(packet=STLPktBuilder(pkt=padded(base, a.lat_frame)),
                         mode=STLTXCont(pps=a.lat_pps),
                         flow_stats=STLFlowLatencyStats(pg_id=a.pg_id))]
    if a.bg_mbps > 0:
        bg = Ether() / IP(src=a.src, dst=a.dst) / UDP(sport=a.bg_sport, dport=a.bg_dport)
        streams.append(STLStream(packet=STLPktBuilder(pkt=padded(bg, a.bg_frame)),
                                 mode=STLTXCont(bps_L2=a.bg_mbps * 1e6)))

    c = STLClient(server=a.server, sync_port=a.sync_port)
    c.connect()
    try:
        c.acquire(ports=[0], force=True)
        c.reset(ports=[0])
        c.set_service_mode(ports=[0], enabled=True)
        c.resolve(ports=[0])
        c.set_service_mode(ports=[0], enabled=False)
        c.add_streams(streams, ports=[0])
        c.clear_stats()
        c.start(ports=[0], duration=a.duration + a.warmup)
        time.sleep(a.warmup)                          # prelazni period (ARP, kesevi) se ne racuna
        c.clear_stats()
        t0 = time.time()
        series = []
        while c.is_traffic_active(ports=[0]):
            time.sleep(a.sample)
            lat, fs = pg_stats(c, a.pg_id)
            l = lat.get("latency", {})
            series.append({"t": round(time.time() - t0, 3), "tx": total(fs, "tx_pkts"), "rx": total(fs, "rx_pkts"),
                           "last_max_us": l.get("last_max"), "avg_us": l.get("average"),
                           "jitter_us": l.get("jitter")})
        t1 = time.time()
        time.sleep(1.0)                               # dolazak poslednjih reflektovanih paketa
        lat, fs = pg_stats(c, a.pg_id)
        port = c.get_stats()[0]
        l = lat.get("latency", {})
        hist = l.get("histogram", {})
        tx, rx = total(fs, "tx_pkts"), total(fs, "rx_pkts")
        lat_us = {"min": l.get("total_min"), "max": l.get("total_max"), "avg": l.get("average"),
                  "jitter": l.get("jitter")}
        lat_us.update(hist_percentiles(hist))
        print(json.dumps({
            "label": a.label, "src": a.src, "dst": a.dst, "trex_mac": read_mac(),
            "duration_s": a.duration, "warmup_s": a.warmup, "t_start": t0, "t_end": t1, "elapsed_s": round(t1 - t0, 3),
            "lat_pps": a.lat_pps, "lat_frame": a.lat_frame, "lat_port": a.lat_port, "lat_sport": a.lat_sport, "pg_id": a.pg_id,
            "bg_mbps": a.bg_mbps, "bg_frame": a.bg_frame, "bg_sport": a.bg_sport,
            "lat_tx_pkts": tx, "lat_rx_pkts": rx,
            "lat_loss_pct": round(100.0 * (tx - rx) / tx, 4) if tx else None,
            "lat_us": lat_us, "err_cntrs": lat.get("err_cntrs", {}),
            "percentile_method": "TRex histogram, linearna interpolacija unutar korpe",
            "histogram_us": hist, "series": series,
            "port0": {k: port.get(k) for k in ("opackets", "obytes", "ipackets", "ibytes", "oerrors", "ierrors")},
        }))
    finally:
        c.disconnect()


if __name__ == "__main__":
    main()
