# microEUKscope

A toolkit for micro-eukaryote metagenomics with two parts:

1) **Customized Database Builder (Kaiju-compatible)** — create **Kaiju-ready protein FASTAs** from local BLAST v5 `nr` and/or your own FASTAs, then index with Kaiju. It provides:
  
a) Scripts to retrieve target TaxIDs and collect all descendants via NCBI taxdump.

b) Scripts to download and update protein FASTAs from JGI MycoCosm and PhycoCosm.

c) A one-shot builder that merges all input FASTAs and indexes for Kaiju (.bwt/.fmi).

2) **Analysis Pipeline** — extract, classify, and summarize **microeukaryotic contigs** from metagenomic assemblies using **Tiara → Kaiju → EukRep**, with per-sample stats and Krona HTML summaries.

---

## What’s included

- **dbbuilder/** — Database Builder. Scripts to:
  - expand/resolve target TaxIDs via NCBI taxdump (handles merged/deprecated IDs),
  - subset local BLAST `nr` with `blastdbcmd` (no `prot.accession2taxid` needed),
  - write Kaiju-style headers `>ACCESSION_TAXID` (version-insensitive exclude list),
  - (optionally) **merge multiple FASTAs** and **build Kaiju `.bwt/.fmi`** indexes.
- **pipeline/** — the microEUKscope pipeline: Tiara classification, Kaiju classification, EukRep filtering, coverage/mapping summaries, and Krona reports.
- **env/** — env for dbbuilder and full pipeline.
- **config/** — example configs (`dbbuilder-example.env`, `config-example.env`).

---

## Installation

### 1) Clone
```bash
git clone https://github.com/m-kluge/microEUKscope.git
cd microEUKscope
```

### 2) Create the conda/mamba env
```bash
# conda
conda env create -f environment.yml -n microEUKscope
conda activate microEUKscope

# OR micromamba
micromamba env create -f environment.yml -n microEUKscope
micromamba activate microEUKscope
```
> **Compatibility note:** EukRep requires **scikit-learn 0.23.x** (model pickle). The provided environment is pinned accordingly.


## Running

Please see README files for dbbuilder and microEUKscope pipeline:


Database Builder: docs/dbbuilder.md

Pipeline guide: docs/pipeline.md






