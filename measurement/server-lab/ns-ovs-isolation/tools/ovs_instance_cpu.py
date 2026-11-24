#!/usr/bin/env python3
"""
ovs_instance_cpu.py - CPU po OvS instanci (kernel datapath + userspace procesi)
================================================================================

Za svaku OvS instancu u lab-u (tier0 = OvS na hostu, ovs-1..3 = OvS u Docker
kontejnerima, svaka u svom mreznom namespace-u) meri:

  kernel   CPU vreme kernel datapath-a te instance (eBPF, ovs_vport_receive),
           ekskluzivno, rasporedjeno po mreznom namespace-u ulaznog uredjaja
  user/sys CPU procesa ovs-vswitchd i ovsdb-server te instance (/proc/<pid>/stat)
  pps      paketi koje je datapath te instance obradio

Procenti su "% jednog jezgra" (100% = jedno jezgro potpuno zauzeto).
U JSONL se upisuje i "% cele masine" (podeljeno brojem jezgara).

Poredjenja radi ispisuje se i sistemski softirq (/proc/stat), jer se kernel
datapath izvrsava uglavnom u NET_RX softirq kontekstu.

POKRETANJE (zahteva root zbog eBPF-a):
  sudo python3 ovs_instance_cpu.py                     # 1 s interval, do Ctrl+C
  sudo python3 ovs_instance_cpu.py -i 0.5 -d 30 -o test.jsonl
"""
import argparse
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone

from bcc import BPF

HERE = os.path.dirname(os.path.abspath(__file__))
BPF_SRC = os.path.join(HERE, "ovs_instance_cpu.bpf.c")
OVS_COMMS = ("ovs-vswitchd", "ovsdb-server")
NCPU = os.cpu_count()
HZ = os.sysconf("SC_CLK_TCK")


def netns_inum(path):
    try:
        return os.stat(path).st_ino
    except OSError:
        return None


def discover_instances():
    """{netns inode: ime instance} - host = tier0, /run/netns/<ime> = tier1."""
    names = {}
    host = netns_inum("/proc/1/ns/net")
    if host:
        names[host] = "tier0"
    if os.path.isdir("/run/netns"):
        for n in sorted(os.listdir("/run/netns")):
            ino = netns_inum(os.path.join("/run/netns", n))
            if ino and ino not in names:
                names[ino] = n
    return names


def ovs_process_times():
    """{netns inode: (utime_ticks, stime_ticks, broj procesa)} za OvS procese."""
    res = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                s = f.read()
            comm = s[s.index("(") + 1:s.rindex(")")]
            if comm not in OVS_COMMS:
                continue
            fields = s[s.rindex(")") + 2:].split()
            ut, st = int(fields[11]), int(fields[12])
            ino = os.stat(f"/proc/{pid}/ns/net").st_ino
        except (OSError, ValueError):
            continue
        u, k, c = res.get(ino, (0, 0, 0))
        res[ino] = (u + ut, k + st, c + 1)
    return res


def proc_stat():
    """Ukupni tick-ovi iz /proc/stat: (ukupno, softirq, system)."""
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    # user nice system idle iowait irq softirq steal guest guest_nice
    return sum(v[:8]), v[6], v[2]


def read_bpf(table):
    out = {}
    for k, v in table.items():
        out[k.value] = (v.ns, v.packets, v.bytes)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-i", "--interval", type=float, default=1.0, help="interval u sekundama (1.0)")
    ap.add_argument("-d", "--duration", type=float, default=0, help="trajanje u sekundama (0 = do Ctrl+C)")
    ap.add_argument("-o", "--output", help="JSONL log fajl")
    ap.add_argument("-q", "--quiet", action="store_true", help="bez ispisa tabele")
    args = ap.parse_args()

    if os.geteuid() != 0:
        sys.exit("Potreban je root (eBPF): sudo python3 ovs_instance_cpu.py")

    b = BPF(src_file=BPF_SRC)
    b.attach_kprobe(event="ovs_vport_receive", fn_name="on_entry")
    b.attach_kretprobe(event="ovs_vport_receive", fn_name="on_return", maxactive=64)
    table = b.get_table("per_netns")
    overflow = b.get_table("overflow")

    names = discover_instances()
    order = list(names.values())
    log = open(args.output, "a") if args.output else None
    if log:
        log.write(json.dumps({"event": "start", "hostname": os.uname().nodename, "ncpu": NCPU,
                              "interval": args.interval, "instances": order,
                              "timestamp": datetime.now(timezone.utc).isoformat()}) + "\n")

    stop = [False]
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__(0, True))
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__(0, True))

    prev_b, prev_p, prev_s, prev_t = read_bpf(table), ovs_process_times(), proc_stat(), time.monotonic()
    t0 = prev_t
    hdr = f"{'instanca':<9}{'kernel%':>9}{'user%':>8}{'sys%':>7}{'ukupno%':>9}{'kpps':>9}{'ns/pkt':>8}{'proc':>5}"
    if not args.quiet:
        print(f"Merenje po OvS instanci, interval {args.interval}s, {NCPU} jezgara; % = % jednog jezgra. Ctrl+C za kraj.")

    while not stop[0]:
        time.sleep(args.interval)
        cur_b, cur_p, cur_s, now = read_bpf(table), ovs_process_times(), proc_stat(), time.monotonic()
        dt = now - prev_t
        ticks = max(cur_s[0] - prev_s[0], 1)
        softirq_pct = (cur_s[1] - prev_s[1]) / ticks * 100 * NCPU   # u % jednog jezgra
        system_pct = (cur_s[2] - prev_s[2]) / ticks * 100 * NCPU

        # nova instanca (npr. dodat kontejner) se otkriva u hodu
        for ino, n in discover_instances().items():
            if ino not in names:
                names[ino] = n
                order.append(n)

        rows = {}
        for ino in set(cur_b) | set(cur_p) | set(names):
            name = names.get(ino, f"netns:{ino}")
            ns, pk, by = (a - c for a, c in zip(cur_b.get(ino, (0, 0, 0)), prev_b.get(ino, (0, 0, 0))))
            u1, s1, cnt = cur_p.get(ino, (0, 0, 0))
            u0, s0, _ = prev_p.get(ino, (u1, s1, 0))
            kern = ns / (dt * 1e9) * 100
            user = (u1 - u0) / HZ / dt * 100
            sysc = (s1 - s0) / HZ / dt * 100
            rows[name] = {
                "kernel_pct": round(kern, 3), "user_pct": round(user, 3), "sys_pct": round(sysc, 3),
                "total_pct": round(kern + user + sysc, 3),
                "total_machine_pct": round((kern + user + sysc) / NCPU, 4),
                "pps": round(pk / dt, 1), "mbps": round(by * 8 / dt / 1e6, 3),
                "ns_per_pkt": round(ns / pk, 1) if pk else 0, "procs": cnt,
            }
            if name not in order:
                order.append(name)

        kern_sum = sum(r["kernel_pct"] for r in rows.values())
        if log:
            log.write(json.dumps({"event": "metrics", "timestamp": datetime.now(timezone.utc).isoformat(),
                                  "t": round(now - t0, 3), "dt": round(dt, 4), "instances": rows,
                                  "system": {"softirq_pct": round(softirq_pct, 3), "system_pct": round(system_pct, 3),
                                             "kernel_datapath_sum_pct": round(kern_sum, 3)},
                                  "bpf_stack_overflow": overflow[0].value}) + "\n")
            log.flush()
        if not args.quiet:
            print(f"\n[{now - t0:6.1f}s]  softirq sistem: {softirq_pct:6.2f}%   zbir kernel datapath: {kern_sum:6.2f}%")
            print(hdr)
            for name in order:
                r = rows.get(name)
                if r:
                    print(f"{name:<9}{r['kernel_pct']:>9.2f}{r['user_pct']:>8.2f}{r['sys_pct']:>7.2f}"
                          f"{r['total_pct']:>9.2f}{r['pps'] / 1000:>9.1f}{r['ns_per_pkt']:>8.0f}{r['procs']:>5}")
        prev_b, prev_p, prev_s, prev_t = cur_b, cur_p, cur_s, now
        if args.duration and now - t0 >= args.duration:
            break

    if log:
        log.close()


if __name__ == "__main__":
    main()
