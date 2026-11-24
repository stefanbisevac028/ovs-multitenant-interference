#!/usr/bin/env python3
"""
trex_flow.py - interferencija / kalibracija: jedan fiksni UDP tok zadate brzine u pps iz jednog TRex kontejnera
===================================================================================================

Jedan tok (fiksna 5-torka: src, dst, sport, dport), pa je posle prvog paketa megaflow unos u kesu i
nema upcall-a. Izbor --sport odredjuje u koji RSS red kartice servera tok pada (kalibracija).
Rezultat: jedan JSON red na stdout (ostvarena brzina slanja i brojaci porta).

Primeri (sa traffic-generator-a, preko run_trex.sh):
  ./run_trex.sh flow 1 --pps 200000 --frame 64 --duration 30
  ./run_trex.sh flow 2 --pps 50000 --frame 1400 --duration 30 --sport 1030
"""
import argparse
import json
import sys
import time

sys.path.insert(0, "/opt/trex/automation/trex_control_plane/interactive")
from trex.stl.api import STLClient, STLStream, STLPktBuilder, STLTXCont, Ether, IP, UDP, TCP  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--dst", required=True)
    ap.add_argument("--pps", type=float, required=True, help="ciljna brzina slanja u paketima u sekundi")
    ap.add_argument("--frame", type=int, default=64, help="velicina okvira sa FCS-om (64 B)")
    ap.add_argument("--duration", type=float, default=30)
    ap.add_argument("--sport", type=int, default=1025, help="UDP src port (bira RSS red na serveru)")
    ap.add_argument("--dport", type=int, default=5001)
    ap.add_argument("--proto", choices=["udp", "tcp"], default="udp",
                    help="udp (podrazumevano) ili tcp: TCP segmenti fiksne 5-torke sa RST zastavicom (prijemni stek ne odgovara), bez veze")
    ap.add_argument("--label", default="")
    ap.add_argument("--server", default="localhost")
    ap.add_argument("--sync-port", type=int, default=4501)
    a = ap.parse_args()

    l4 = TCP(sport=a.sport, dport=a.dport, flags="R") if a.proto == "tcp" else UDP(sport=a.sport, dport=a.dport)
    base = Ether() / IP(src=a.src, dst=a.dst) / l4
    pkt = base / ("x" * max(0, a.frame - 4 - len(base)))
    c = STLClient(server=a.server, sync_port=a.sync_port)
    c.connect()
    try:
        c.acquire(ports=[0], force=True)
        c.reset(ports=[0])
        c.set_service_mode(ports=[0], enabled=True)
        c.resolve(ports=[0])
        c.set_service_mode(ports=[0], enabled=False)
        c.add_streams(STLStream(packet=STLPktBuilder(pkt=pkt), mode=STLTXCont(pps=a.pps)), ports=[0])
        c.clear_stats()
        t0 = time.time()
        c.start(ports=[0], duration=a.duration)
        c.wait_on_traffic(ports=[0])
        t1 = time.time()
        s = c.get_stats()[0]
        el = t1 - t0
        print(json.dumps({
            "label": a.label, "src": a.src, "dst": a.dst, "sport": a.sport, "dport": a.dport,
            "target_pps": a.pps, "frame_bytes": a.frame, "proto": a.proto, "duration_s": a.duration,
            "t_start": t0, "t_end": t1, "elapsed_s": round(el, 3),
            "opackets": s["opackets"], "obytes": s["obytes"], "oerrors": s["oerrors"],
            "ipackets": s["ipackets"], "ierrors": s["ierrors"],
            "avg_tx_pps": round(s["opackets"] / el, 1),
            "avg_tx_mbps_L2": round(s["obytes"] * 8 / el / 1e6, 2),
            "achieved_ratio": round(s["opackets"] / el / a.pps, 4) if a.pps else None,
        }))
    finally:
        c.disconnect()


if __name__ == "__main__":
    main()
