# Interferencija tenanata u multitenant Open vSwitch okruženju

Podaci, merne skripte i analiza za rad *„Interferencija u multitenant Open vSwitch okruženju:
mehanizam, zakonitosti i kontrola gubitaka na brzoj putanji“*. Repozitorijum sadrži sva merenja brze
putanje korišćena u radu (2060 merenja), skripte kojima su izvedena i skripte koje iz sirovih podataka
ponovo prave sve tabele i slike.

## Varijante

| Oznaka | Opis | Šta se razdvaja po tenantu |
|---|---|---|
| A0 | beslojni OVS, jedan bridge na hostu | ništa (samo adrese) |
| A1 | beslojni OVS, bridge po tenantu (patch portovi) | logički bridge |
| A2 | dvoslojna hijerarhija: tier1 OVS instanca po tenantu u imenskom prostoru | procesi, datapath, konfiguracija |
| A3 | A2 + cpuset za tier1 kontejnere ({4,12}, {5,13}, {6,14}) | + CPU spore putanje |
| A4 | A3 + RPS po tenantu na `uplink0` | + CPU tier1 brze putanje |

## Eksperimenti

| Folder | Šta se meri | Varijante | Parametri |
|---|---|---|---|
| `data/raw/interference_2x2/` | interferencija na brzoj putanji, dizajn 2×2 | A0–A4 | 4 ćelije: RPS kartice uzak (`0000`) / širok (`ffff`) × isti / različiti red; opterećujući tok 64 B, 0–450 kpps; posmatrani tenanti 20 kpps + latency 1000 pps |
| `data/raw/frame_size/` | isto, veći okviri opterećujućeg toka | A0, A2, A4 | 512 B i 1400 B; uzak RPS, isti red; 0/150/300/450 kpps |
| `data/raw/tcp/` | isto, TCP opterećujući tok | A0, A2, A4 | TCP 64 B (segmenti fiksnog toka sa RST zastavicom, bez veze) |
| `data/raw/self_load/` | opterećujući tenant sam (samoopterećenje) | A0, A2, A4 | 50–450 kpps, uzak RPS |
| `data/raw/cpu_budget/` | CPU vreme po paketu (CPU budžet) | A0, A1, A2 | jedan tok 64 B, 100–250 kpps, uzak RPS |

Osnovni okvir je 64 B; gornja veličina okvira je 1400 B (blizu MTU-a od 1500 B, uz zaglavlja), a ne
1500 B. Svako merenje traje 15 s posle 2 s zagrevanja, sa 10 ponavljanja po ćeliji i slučajnim
redosledom intenziteta. Platforma: server AMD Ryzen 7 2700X, Ubuntu 24.04 (kernel 6.8), OVS 3.3.9,
Netronome Agilio CX 2×10G (firmware `bpf`, bez ntuple filtera); generator Intel i3-9100F sa TRex v3.06
(af_packet) i Mellanox ConnectX.

## Struktura

```
data/raw/<eksperiment>/<grupa>/<varijanta>/p<kpps>k_r<NN>/
    server/cpu.jsonl.gz      eBPF CPU vreme OVS datapath-a po instanci (0,5 s)
    server/ovs.jsonl.gz      brojači OVS datapath-a, softnet_stat i softirq po jezgru (1 s)
    server/meta.json         konfiguracija kartice i sistema u trenutku merenja
    generator/tenantN.json   TRex rezultat tenanta N (poslato, latencija, histogram)
data/raw/index/              spisak merenja po eksperimentu (kolona run = putanja merenja)
measurement/server-lab/      osnovni lab na serveru (OVS image, tier0/tier1, servisi; lab.env)
  ns-ovs-isolation/          varijante A0–A4, merenje, RPS kartice, eBPF alat, orkestracija kampanja
measurement/traffic-generator/  osnovni lab na generatoru (TRex kontejneri; lab.env)
  ns-ovs-isolation/scripts/  TRex profili (opterećujući tok, pozadinski i latency tok)
analysis/                    obrada, statistika, tabele i slike (01_ … 08_, run_all.sh)
results/processed/           izvedeni CSV/JSON (po merenju, po ćeliji, statistički testovi)
results/tables/, figures/    tabele (LaTeX) i slike iz rada
mapping_old_to_new.csv       originalni naziv merenja -> nova putanja
mapping_names.csv          originalni naziv skripte, tabele ili slike -> novi naziv
```

Svako merenje je određeno svojom putanjom, npr.
`data/raw/interference_2x2/rps-narrow_queue-same/A2/p450k_r01/` (A2, uzak RPS, isti red, 450 kpps,
ponavljanje 1). Oznake varijanti u indeksima i izvedenim CSV-ovima: `A2n` = A2 uz uzak RPS, `A2w` = uz širok RPS,
`A2n_f1400` = okvir 1400 B, `A2n_tcp` = TCP.

## Reprodukcija

Potrebno: Python 3 sa `numpy` i `matplotlib`.

```
bash analysis/run_all.sh
```

| Skripta | Izlaz |
|---|---|
| `01_process_runs.py` | `results/processed/{interference,cpu_budget,self_load}_runs.csv`, `interference_cells.csv` |
| `02_interference_tables.py` | `table_2x2`, `table_mehanizam`, `table_cpu_budget`, `table_self_load`; `rev_tests_vs_A0.csv` |
| `03_tests_vs_baseline.py` | `rev_tests_vs_P0.csv` (P = 450 kpps prema P = 0) |
| `04_frame_size_tcp.py` | `table_frame_size_tcp` |
| `05_capacity_model.py` | `table_capacity_model`, `rev_model.csv` (tačka zasićenja) |
| `06_interference_law.py` | `table_rho`: stepen opterećenja ρ i isporuka min(1, 1/ρ) |
| `07_loss_latency_tradeoff.py` | `table_loss_latency`: kompromis gubitka i latencije |
| `08_paper_figures.py` | slike iz sekcije 5 rada: `k5_toplotna_mapa.pdf` (sl. 3), `k5_deljeno_jezgro.pdf` (sl. 4), `k5_okviri_tcp.pdf` (sl. 5), `k5_zakon_cena.pdf` (sl. 6) |

Slike `overview_isporuka.pdf` i `overview_p50.pdf` su pregledne (sve ćelije i intenziteti) i nisu u radu.

Statistika: Mann–Whitney test, Holmova korekcija, Cliff-ov δ, bootstrap intervali (`analysis/stats.py`). Testovi
korišćeni u radu su u `rev_tests_vs_A0.csv` i `rev_tests_vs_P0.csv`; kolone `p_holm`, `ci_lo` i
`ci_hi` u pomoćnom `interference_cells.csv` zavise od broja poređenja u porodici i od bootstrap uzorkovanja, pa
nisu namenjene citiranju.

## Rad

Sam rad nije deo repozitorijuma. Slike iz sekcije 5 rada (`results/figures/k5_*.pdf`) i sve tabele
(`results/tables/`) dobijaju se iz sirovih podataka skriptom `analysis/run_all.sh`.

## Merne skripte

Folder `measurement/` ima isti raspored kao laboratorija (`~/server-lab` na serveru,
`~/traffic-generator` na generatoru), pa relativne putanje u skriptama važe bez izmena. Imena kartica,
adrese i jezgra su u `lab.env` i `ns-ovs-isolation/ns.env`. Pristup generatoru i serveru zadaje se
promenljivim okruženja `SRV_HOST`, `GEN_HOST` (npr. `user@10.0.0.2`), `SRV_HOSTNAME` i `SSH_KEY`.
Osnovni lab se podiže redom `1 - Installation`, `2 - Setup Lab`, `3 - Start Lab`; TRex image se gradi iz
arhive `v3.06.tar.gz` sa sajta TRex projekta, koja nije u repozitorijumu. Kampanje se pokreću na
serveru: `orchestrator/run_campaign.sh` (interferencija u četiri ćelije, samoopterećenje, CPU budžet) i
`orchestrator/run_campaign_frames_tcp.sh` (okviri, TCP, ćelija „širok RPS, različiti redovi“). Pojedinačne
serije pokreću `run_interference.sh`, `run_self_load.sh` i `run_cpu_budget.sh`, a na generatoru
`run_trex.sh flow` (`trex_flow.py`) i `trex_latency.py`. CPU vreme po OVS
instanci meri `tools/ovs_instance_cpu.py` (eBPF kprobe/kretprobe na `ovs_vport_receive`).

Merenja spore putanje nisu deo ovog repozitorijuma.

## Nazivi i veza sa laboratorijom

Folderi, fajlovi i skripte imaju opisne nazive (`interference_2x2`, `frame_size`, `tcp`, `self_load`,
`cpu_budget`). Sadržaj sirovih fajlova nije menjan: polje `label` u `generator/tenantN.json` zadržava
interno ime merenja koje je skripta upisala u trenutku merenja. Veza tog imena i putanje merenja je u
`mapping_old_to_new.csv`, a veza ranijih i sadašnjih naziva skripti, indeksa, tabela i slika u
`mapping_names.csv`. Merne skripte u `measurement/` se od verzija pokrenutih u laboratoriji razlikuju
samo u nazivima fajlova i prefiksima imena merenja i u parametrizovanim adresama (`SRV_HOST`,
`GEN_HOST`, `SSH_KEY`).
