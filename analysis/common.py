"""Zajednicke putanje i pristup podacima repozitorijuma.

data/raw/<eksperiment>/<grupa>/<varijanta>/p<kpps>k_r<NN>/
    server/cpu.jsonl.gz    eBPF CPU vreme kernel datapath-a po OVS instanci (0,5 s)
    server/ovs.jsonl.gz    brojaci OVS datapath-a, softnet_stat i softirq po jezgru (1 s)
    server/meta.json       konfiguracija kartice i sistema u trenutku merenja
    generator/tenantN.json rezultat TRex-a za tenanta N (latencija, poslati paketi)
data/raw/index/{interference,self_load,cpu_budget}_runs.csv  spisak merenja (kolona run = putanja)
"""
import csv, gzip, os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "data", "raw")
INDEX = os.path.join(RAW, "index")
PROC = os.path.join(REPO, "results", "processed")
TAB = os.path.join(REPO, "results", "tables")
FIG = os.path.join(REPO, "results", "figures")
for _d in (PROC, TAB, FIG):
    os.makedirs(_d, exist_ok=True)

_PATH = {}
for _f in ("interference_runs.csv", "self_load_runs.csv", "cpu_budget_runs.csv"):
    _p = os.path.join(INDEX, _f)
    if os.path.exists(_p):
        for _r in csv.DictReader(open(_p)):
            _PATH[_r["run"]] = os.path.join(RAW, _r["run"])


def index_csv(name):
    """putanja indeksa merenja (npr. 'interference_runs.csv'); None ako ne postoji"""
    p = os.path.join(INDEX, name)
    return p if os.path.exists(p) else None


def server_file(run, fn):
    """putanja serverskog fajla merenja (cpu.jsonl, ovs.jsonl, meta.json); .gz ako postoji"""
    base = os.path.join(_PATH.get(run, os.path.join(RAW, "_nepostoji_", run)), "server", fn)
    return base + ".gz" if os.path.exists(base + ".gz") else base


def gen_file(run, tenant=1):
    """putanja rezultata generatora za tenanta"""
    return os.path.join(_PATH.get(run, os.path.join(RAW, "_nepostoji_", run)), "generator", f"tenant{tenant}.json")


def opentext(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)
