#!/bin/bash
# Reprodukuje sve izvedene podatke, tabele i slike iz data/raw.
#   bash analysis/run_all.sh
set -euo pipefail
cd "$(dirname "$0")"
python3 01_process_runs.py          # sirova merenja -> results/processed/{interference,cpu_budget,self_load}_runs.csv
python3 02_interference_tables.py   # interferencija: tabele 2x2, mehanizam, CPU budzet, samoopterecenje; testovi prema A0
python3 03_tests_vs_baseline.py     # testovi P=450k prema P=0
python3 04_frame_size_tcp.py        # okviri 512/1400 B i TCP
python3 05_capacity_model.py        # model kapaciteta jezgra (tacka zasicenja)
python3 06_interference_law.py      # stepen opterecenja rho i isporuka min(1, 1/rho)
python3 07_loss_latency_tradeoff.py # kompromis gubitka i latencije
python3 08_paper_figures.py         # slike iz sekcije 5 rada (results/figures/k5_*.pdf)
echo "gotovo: results/processed, results/tables, results/figures"
