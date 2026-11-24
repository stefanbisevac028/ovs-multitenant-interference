#!/usr/bin/env python3
# Kratak UDP test iz jednog TRex kontejnera: trex_udp.py <src_ip> <dst_ip> <pps> <sekundi> [velicina]
import sys
sys.path.insert(0, "/opt/trex/automation/trex_control_plane/interactive")
from trex.stl.api import STLClient, STLStream, STLPktBuilder, STLTXCont, Ether, IP, UDP

src, dst, pps, dur = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
size = int(sys.argv[5]) if len(sys.argv) > 5 else 64

base = Ether() / IP(src=src, dst=dst) / UDP(sport=1025, dport=5001)
pkt = base / ("x" * max(0, size - 4 - len(base)))
c = STLClient()
c.connect()
try:
    c.acquire(ports=[0], force=True)
    c.reset(ports=[0])
    c.set_service_mode(ports=[0], enabled=True)
    c.resolve(ports=[0])
    c.set_service_mode(ports=[0], enabled=False)
    c.add_streams(STLStream(packet=STLPktBuilder(pkt=pkt), mode=STLTXCont(pps=pps)), ports=[0])
    c.clear_stats()
    c.start(ports=[0], duration=dur)
    c.wait_on_traffic(ports=[0])
    s = c.get_stats()[0]
    print(f"{src}->{dst}: tx {s['opackets']} pkt, {s['tx_pps']:.0f} pps (poslednje)")
finally:
    c.disconnect()
