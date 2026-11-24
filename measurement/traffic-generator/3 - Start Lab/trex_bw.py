#!/usr/bin/env python3
# UDP tok zadatog protoka iz jednog TRex kontejnera, rezultat kao jedan JSON red na stdout.
#   trex_bw.py <src_ip> <dst_ip> <mbps> <sekundi> [velicina_okvira_B]
# Protok je L2 (Ethernet okvir sa FCS-om, bez preambule i IFG-a), velicina okvira podrazumevano 1400 B.
import json
import sys
import time
sys.path.insert(0, "/opt/trex/automation/trex_control_plane/interactive")
from trex.stl.api import STLClient, STLStream, STLPktBuilder, STLTXCont, Ether, IP, UDP

src, dst, mbps, dur = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
size = int(sys.argv[5]) if len(sys.argv) > 5 else 1400

base = Ether() / IP(src=src, dst=dst) / UDP(sport=1025, dport=5001)
pkt = base / ("x" * max(0, size - 4 - len(base)))           # TRex dodaje 4 B FCS
c = STLClient()
c.connect()
try:
    c.acquire(ports=[0], force=True)
    c.reset(ports=[0])
    c.set_service_mode(ports=[0], enabled=True)
    c.resolve(ports=[0])
    c.set_service_mode(ports=[0], enabled=False)
    c.add_streams(STLStream(packet=STLPktBuilder(pkt=pkt), mode=STLTXCont(bps_L2=mbps * 1e6)), ports=[0])
    c.clear_stats()
    t0 = time.time()
    c.start(ports=[0], duration=dur)
    c.wait_on_traffic(ports=[0])
    t1 = time.time()
    s = c.get_stats()[0]
    el = t1 - t0
    print(json.dumps({
        "src": src, "dst": dst, "target_mbps": mbps, "duration_s": dur, "frame_bytes": size,
        "t_start": t0, "t_end": t1, "elapsed_s": round(el, 3),
        "opackets": s["opackets"], "obytes": s["obytes"], "oerrors": s["oerrors"],
        "ipackets": s["ipackets"], "ibytes": s["ibytes"], "ierrors": s["ierrors"],
        "avg_tx_mbps_obytes": round(s["obytes"] * 8 / el / 1e6, 2),
        "avg_tx_pps": round(s["opackets"] / el, 1),
    }))
finally:
    c.disconnect()
