#!/usr/bin/env python3
"""
ovs_snapshot.py - periodicni snimci stanja OvS instanci (samo citanje), JSONL
==============================================================================

Instance: tier0 (sistemski OvS na hostu) i svaki ovs-vswitchd u drugom mreznom namespace-u
(tier1 kontejneri ovs-N; ime iz /run/netns). Komande idu preko kontrolnog socket-a procesa
(/proc/<pid>/root/run/openvswitch/ovs-vswitchd.<pid>.ctl), bez docker exec-a.

Po instanci i snimku:
  dpctl/show   lookups hit/missed/lost, broj megaflow unosa, maske (total, hit/pkt), hit-rate keša
  upcall/show  flows current/avg/max/limit, dump duration
Sistemski: NET_RX softirq po CPU-u (/proc/softirqs), prekidi redova kartice (/proc/interrupts) i
paketi po redu prijema kartice (ethtool -S) paketi primljeni na eth0 servisa i
softnet brojaci po CPU-u (obradjeno, odbaceno, squeeze).

POKRETANJE (root):
  sudo python3 ovs_snapshot.py -i 1 -d 30 -o ovs.jsonl
  sudo python3 ovs_snapshot.py --meta        # jednokratno: konfiguracija (varijanta, cpuset, RPS, IRQ)
"""
import argparse
import glob
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
NS_DIR = os.path.dirname(HERE)
HZ = os.sysconf("SC_CLK_TCK")
LAB_DIR = os.path.dirname(NS_DIR)


def netns_inum(path):
    try:
        return os.stat(path).st_ino
    except OSError:
        return None


def netns_names():
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


def pids_of(comm):
    out = []
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open(f"/proc/{p}/comm") as f:
                if f.read().strip() == comm:
                    out.append(int(p))
        except OSError:
            pass
    return out


def instances():
    """{ime: {"pid": vswitchd pid, "ctl": socket, "ovsdb_pid": pid}}"""
    names = netns_names()
    res = {}
    for comm, key in (("ovs-vswitchd", "pid"), ("ovsdb-server", "ovsdb_pid")):
        for pid in pids_of(comm):
            ino = netns_inum(f"/proc/{pid}/ns/net")
            name = names.get(ino, f"netns:{ino}")
            res.setdefault(name, {})[key] = pid
    for name, d in res.items():
        pid = d.get("pid")
        if not pid:
            continue
        cand = [f"/proc/{pid}/root/run/openvswitch/ovs-vswitchd.{pid}.ctl"]
        cand += glob.glob(f"/proc/{pid}/root/run/openvswitch/ovs-vswitchd.*.ctl")
        cand += glob.glob(f"/proc/{pid}/root/var/run/openvswitch/ovs-vswitchd.*.ctl")
        d["ctl"] = next((c for c in cand if os.path.exists(c)), None)
    return res


def appctl(ctl, *cmd):
    try:
        r = subprocess.run(["ovs-appctl", "-t", ctl, *cmd], capture_output=True, text=True, timeout=3)
        return r.stdout if r.returncode == 0 else None
    except (subprocess.SubprocessError, OSError):
        return None


def num(rx, text, cast=int):
    m = re.search(rx, text or "")
    return cast(m.group(1)) if m else None


def parse_dpctl(t):
    if not t:
        return None
    return {
        "hit": num(r"lookups: hit:(\d+)", t), "missed": num(r"missed:(\d+)", t),
        "lost": num(r"lost:(\d+)", t), "flows": num(r"flows: (\d+)", t),
        "masks_total": num(r"masks: hit:\d+ total:(\d+)", t),
        "masks_hit_per_pkt": num(r"hit/pkt:([\d.]+)", t, float),
        "cache_hit_rate": num(r"hit-rate:([\d.]+)%", t, float),
    }


def parse_upcall(t):
    if not t:
        return None
    m = re.search(r"flows\s*:\s*\(current (\d+)\) \(avg (\d+)\) \(max (\d+)\) \(limit (\d+)\)", t)
    d = {"dump_duration_ms": num(r"dump duration\s*:\s*(\d+)ms", t)}
    if m:
        d.update(zip(("flows_current", "flows_avg", "flows_max", "flows_limit"), map(int, m.groups())))
    return d


def net_rx_softirq():
    with open("/proc/softirqs") as f:
        for line in f:
            if line.strip().startswith("NET_RX:"):
                return [int(x) for x in line.split()[1:]]
    return None


def nic_irqs(phy):
    res = {}
    with open("/proc/interrupts") as f:
        for line in f:
            parts = line.split()
            if parts and phy in parts[-1]:
                res[parts[-1]] = sum(int(x) for x in parts[1:] if x.isdigit())
    return res


def nic_rxq(phy):
    """paketi po redu prijema kartice (ethtool -S, nfp: rvec_N_rx_pkts)"""
    out = sh(["ethtool", "-S", phy]) or ""
    return {f"q{m.group(1)}": int(m.group(2)) for m in re.finditer(r"rvec_(\d+)_rx_pkts: (\d+)", out)
            if int(m.group(2)) or int(m.group(1)) < 4}


def cpu_ticks():
    """po CPU-u iz /proc/stat: [softirq, irq, system] u USER_HZ tikovima (zatvaranje CPU budzeta)"""
    res = []
    with open("/proc/stat") as f:
        for line in f:
            c = line.split()
            if c[0].startswith("cpu") and c[0] != "cpu":
                res.append([int(c[7]), int(c[6]), int(c[3])])
    return res


def softnet():
    """po CPU-u iz /proc/net/softnet_stat: obradjeno, odbaceno (backlog pun), time_squeeze"""
    res = []
    with open("/proc/net/softnet_stat") as f:
        for line in f:
            c = line.split()
            res.append([int(c[0], 16), int(c[1], 16), int(c[2], 16)])
    return res


_SVC_PIDS = {}


def svc_rx(names=("svc1", "svc2", "svc3")):
    """primljeni paketi na eth0 servisa (/proc/<pid>/net/dev njegovog namespace-a) - isporuka
    tenantu nezavisno od varijante (u A0/A1 nema tier1 instanci)"""
    if not _SVC_PIDS:
        out = sh(["docker", "inspect", "-f", "{{.Name}} {{.State.Pid}}", *names]) or ""
        for line in out.splitlines():
            n, pid = line.split()
            _SVC_PIDS[n.lstrip("/")] = pid
    res = {}
    for n, pid in _SVC_PIDS.items():
        try:
            with open(f"/proc/{pid}/net/dev") as f:
                for line in f:
                    if line.strip().startswith("eth0:"):
                        res[n] = int(line.split(":", 1)[1].split()[1])
        except OSError:
            pass
    return res


def snapshot(phy, raw):
    s = {"ts": time.time(), "utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
         "instances": {}, "net_rx_softirq": net_rx_softirq(), "nic_irq": nic_irqs(phy),
         "nic_rxq_pkts": nic_rxq(phy), "svc_rx_pkts": svc_rx(),
         "softnet": softnet(), "cpu_ticks": cpu_ticks()}
    for name, d in sorted(instances().items()):
        if not d.get("ctl"):
            continue
        dp = appctl(d["ctl"], "dpctl/show")
        up = appctl(d["ctl"], "upcall/show")
        e = {"pid": d.get("pid"), "dp": parse_dpctl(dp), "upcall": parse_upcall(up)}
        if raw:
            e["raw"] = {"dpctl": dp, "upcall": up}
        s["instances"][name] = e
    return s


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None


def md5(path):
    try:
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except OSError:
        return None


def meta(phy):
    applied = []
    try:
        with open(os.path.join(NS_DIR, "state", "applied")) as f:
            applied = [l.strip() for l in f if l.strip()]
    except OSError:
        pass
    variant = next((v for v in ("A0", "A1", "A4", "A3") if v in applied), "A2")
    inst = {}
    for name, d in sorted(instances().items()):
        e = {"vswitchd_pid": d.get("pid"), "ovsdb_pid": d.get("ovsdb_pid")}
        for k in ("pid", "ovsdb_pid"):
            if d.get(k):
                e[("vswitchd" if k == "pid" else "ovsdb") + "_cpus"] = sorted(os.sched_getaffinity(d[k]))
        if name != "tier0" and not name.startswith("netns:"):
            e["docker_cpuset"] = sh(["docker", "inspect", "-f", "{{.HostConfig.CpusetCpus}}", name])
            e["uplink0_rps"] = sh(["ip", "netns", "exec", name, "sh", "-c",
                                   "cat /sys/class/net/uplink0/queues/rx-*/rps_cpus"])
        inst[name] = e
    irq_aff = {}
    with open("/proc/interrupts") as f:
        for line in f:
            parts = line.split()
            if parts and phy in parts[-1]:
                irq = parts[0].rstrip(":")
                try:
                    with open(f"/proc/irq/{irq}/smp_affinity_list") as a:
                        irq_aff[parts[-1]] = a.read().strip()
                except OSError:
                    pass
    with open("/proc/cmdline") as f:
        cmdline = f.read().strip()
    return {
        "utc": datetime.now(timezone.utc).isoformat(timespec="seconds"), "variant": variant,
        "applied": applied, "uname": " ".join(os.uname()), "cmdline": cmdline, "ncpu": os.cpu_count(),
        "lab_env_md5": md5(os.path.join(LAB_DIR, "lab.env")),
        "flows_md5": md5(os.path.join(LAB_DIR, "2 - Setup Lab", "flows.txt")),
        "ovs_tier0_bridges": sh(["ovs-vsctl", "list-br"]),
        "instances": inst, "nic_irq_affinity": irq_aff,
        "ethtool_l": sh(["ethtool", "-l", phy]), "ethtool_c": sh(["ethtool", "-c", phy]),
        "ethtool_g": sh(["ethtool", "-g", phy]), "ethtool_i": sh(["ethtool", "-i", phy]),
        "nic_rps": {os.path.basename(os.path.dirname(f)): open(f).read().strip()
                    for f in sorted(glob.glob(f"/sys/class/net/{phy}/queues/rx-*/rps_cpus"))},
        "user_hz": HZ,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-i", "--interval", type=float, default=1.0, help="interval u sekundama (1.0)")
    ap.add_argument("-d", "--duration", type=float, default=0, help="trajanje u sekundama (0 = do Ctrl+C)")
    ap.add_argument("-o", "--output", help="JSONL fajl (podrazumevano stdout)")
    ap.add_argument("--phy", default="enp5s0np0", help="fizicki interfejs (enp5s0np0)")
    ap.add_argument("--raw", action="store_true", help="u JSONL upisi i sirov izlaz ovs-appctl komandi")
    ap.add_argument("--meta", action="store_true", help="jednokratno ispisi konfiguraciju i izadji")
    a = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("potreban je root (sudo)")
    if a.meta:
        print(json.dumps(meta(a.phy), indent=1))
        return
    stop = {"v": False}
    signal.signal(signal.SIGINT, lambda *_: stop.update(v=True))
    signal.signal(signal.SIGTERM, lambda *_: stop.update(v=True))
    out = open(a.output, "a") if a.output else sys.stdout
    t_end = time.time() + a.duration if a.duration > 0 else None
    nxt = time.time()
    while not stop["v"] and (t_end is None or time.time() < t_end):
        out.write(json.dumps(snapshot(a.phy, a.raw)) + "\n")
        out.flush()
        nxt += a.interval
        time.sleep(max(0.0, nxt - time.time()))
    if out is not sys.stdout:
        out.close()


if __name__ == "__main__":
    main()
