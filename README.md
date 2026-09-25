# microEUKscope 

The microEUKscope pipeline was developed to identify microeukaryotes from assemblies of metagenomic datasets. We have combined and benchmarked existing tools (TIARA, Kaiju, EukRep) to taxonomically annotate contigs, and generate a fasta file with the classified microeukaryotes. The user can also use this pipeline to retrieve the classified prokaryotic sequences.

The pipeline uses a customized nr+euk Kaiju database, which includes microeukaryotic groups ([https://doi.org/10.1016/j.tree.2019.08.008](https://doi.org/10.1016/j.tree.2019.08.008)) and the genomes available at JGI's Mycocosm and Phycocosm. This database is ready to download at Figshare (https://figshare.com/s/d6a335a7a825c74b9d08). 

The setup overview is:

1) Download the microEUKscope GitHub repo (code + config templates)
2) Create the Conda environment (software/tools)
3) Configure `config.env` to connect the repo to the env  
4) Run (SLURM array or local)

This manual explains how the pipeline is installed and can be run on locally and on clusters. 

---
## 1) Big picture: what you’re setting up

The microEUKscope repo allows you to:

1. **Run microEUKscope** on contigs to retrieve a final fasta file with all classified microeukaryotic sequences (Tiara → Kaiju → EukRep → final euk pool). The pipeline is ideally run as **one SLURM array task per sample**.

2. **Help building a customized Kaiju database** (optional):  
   we provide scripts to help you create a **Kaiju-ready protein FASTA subset** from local NCBI BLAST `nr` (v5) and/or JGI Mycocosm/Phycocosm genomes then build the **Kaiju index** (`*.fmi`, etc.) from these FASTAs.

You can do **(1)** without doing **(2)** if you already have a working Kaiju database or download the one available at Figshare.

---
## 2) One-time setup: 

### 2.1 Choose a location for the project in your cluster

microEUKscope can use a lot of computational resources, so it is recommended to be run on a computer cluster. On a cluster you should **avoid putting Conda envs and packages in`$HOME`** (as it can easily exceed your quota + performance).  

Instead you store them in your project space:

```bash
PROJ=/your/project/dir
```

Inside that, you create:
- `$PROJ/conda/pkgs`  → *Conda package cache*
- `$PROJ/conda/envs`  → *Conda environments by prefix*

This makes installs reliable and avoids “disk quota exceeded”.

```bash
# Create conda dirs on project space

mkdir -p $PROJ/conda/pkgs $PROJ/conda/envs

CONDA_PKGS_DIRS="$PROJ/conda/pkgs" export  
CONDA_ENVS_DIRS="$PROJ/conda/envs" export 

```

- `CONDA_PKGS_DIRS` → where packages are downloaded/unpacked (cache)
    
- `CONDA_ENVS_DIRS` → where named envs are stored

### 2.2 Download the repository (GitHub → cluster)

```bash
cd "$PROJ"
git clone https://github.com/m-kluge/microEUKscope.git microEUKscope
cd microEUKscope
```
### 2.3 Conda environment install 

#### Make sure you have conda/miniconda installed or use ```module load``` if available

e.g.:
```bash
module load miniconda3
```

#### Use Conda to create the env **by prefix** to force location off $HOME

```bash
conda env create -f environment.yml -p "$PROJ/conda/envs/microEUKscope"
```

**What this does**

- reads the environment specification (`environment.yml` from the cloned repo)
    
- installs everything into **that absolute folder**

**Why prefix is great on clusters**

- avoids `$HOME/.conda/…`
    
- works well in non-interactive SLURM shells (no `conda activate` needed)
    
---

## 3) Configuration: the pipeline’s “control panel” via ```config.env```


To run microEUKscope, you need to configure it via a `config.env` file, which will connect the repo with the conda installed env and your data. Use a text editor tool to fill up the information about the required inputs in that file. A template of ```config.env``` is provided in the repo.

### 3.1 Copy example configs 

`cp config-example.env config.env`

### 3.2 What goes into `config.env`

For running the microEUKscope pipeline, these are the **core variables** you must set. Use a text editor like ```vim``` to edit the file. `config.env` is what makes the sbatch script portable: it contains the cluster-specific paths & resources.

- `CONTIGS_DIR`  
    Where your input contigs are.
    
- `PROJECT_DIR`  
    Your project working directory (place for outputs, logs, stats).
    
- `KAIJU_DB_DIR`  
    Folder containing Kaiju DB index + taxonomy files:
    
    - `*.fmi`
        
    - `nodes.dmp`
        
    - `names.dmp`
        
- `ENV_PREFIX`  
    The absolute path to your conda env, the same you used here: ```conda env create -f environment.yml -p "$PROJ/conda/envs/microEUKscope"```
    
    `ENV_PREFIX=/path/to/conda/envs/microEUKscope`
    

The remaining information on the config.env is **OPTIONAL** and can remain unchanged. It includes Kaiju/Tiara parameters (which users do not usually change), a possibility to add an additional Kaiju final taxa subset of a desired taxonomic group, and also create a final pool of all classified prokaryotes.

---
## 4) Sample list

Create a plain text file (default name often `sample_list`) with:

- **one sample ID per line**
    
- **no header**
    
Example:

`Sample1`
`Sample2`
`Sample3`

**Why?**  
SLURM array jobs use `SLURM_ARRAY_TASK_ID` (1,2,3,...) to pick the Nth line from that file.

---
## 5) How to run microEUKscope

This guide shows two ways to run the **microEUKscope** pipeline:

- **A)** via SLURM using `sbatch` flags (submits an **array**, one task per sample)
- **B)** Locally, without SLURM (sequential over samples) - be aware of computational resources
### Mode A — SLURM array submission

You submit a job via ```sbatch``` flags from your cluster. The example below also submits an array (one task per sample):

```bash
# ensure config.env has ENV_PREFIX set to your absolute conda prefix

sbatch \
-p core \
-A your-account \
-t 24:00:00 \
-J microEUKscope \
--array=1-$(grep -cve '^\s*$' sample_list) \
--ntasks=1 --cpus-per-task=20 \
--chdir "$(pwd)" \
microEUKscope.sbatch
```

**What happens**

- `--array=1-N` creates N independent tasks
    
- each task runs `microEUKscope.sbatch`
    
- inside the sbatch script, it calls the core runner `microEUKscope_core.sh`
    
- the core script reads line `SLURM_ARRAY_TASK_ID` from `SAMPLE_LIST`
    
- it runs the pipeline only for that sample
    

Useful variants:

- single sample: `--array=7-7`
    
- first 10: `--array=1-10`
    

If you omit `--array`, then the sbatch job runs **once**, and the core script may loop over all samples sequentially (slower, not typical on clusters).

---

### Mode B — Local run (no SLURM, be aware of computational resources)

Process all samples sequentially on your workstation/interactive node:

```bash
source config.env 
export PATH="${ENV_PREFIX}/bin:${PATH}" 
export LD_LIBRARY_PATH="${ENV_PREFIX}/lib:${LD_LIBRARY_PATH:-}"  
bash microEUKscope_core.sh
```

Process a single sample locally using a temporary list:

```bash
printf '%s\n' "Sample_A" > /tmp/one_sample.list SAMPLE_LIST=/tmp/one_sample.list bash microEUKscope_core.sh
```

---

## 6) Outputs

microEUKscope produces a long list of outputs. The most relevant ones are:

```bash
`${OUTPUT_DIR}/${SAMPLE}/   
    ${SAMPLE}.pipeline.run.log   
    08_tiara_kaiju_eukrep.euk-pool.fasta`
    
${STATS_DIR}/${SAMPLE}.pipeline.stats.tsv

${SUMMARY_DIR}/
    08_tiara_kaiju_eukrep.euk-pool_summary.tsv # Kaiju phylum table
    08_tiara_kaiju_eukrep.euk-pool.html # Krona HTML
```

**Interpretation**

- The `*.euk-pool.fasta` is the _final_ filtered euk contig set.
    
- `run.log` for debugging.
    
- The stats TSV for downstream summarization/plotting.
    

---

Here is a full list of the output files:

| File                                                                                          | Content                                                                         |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.pipeline.run.log`                                          | Run log                                                                         |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.out3000.txt`                                               | Tiara classification report for large contigs ≥3k                               |
| `${OUTPUT_DIR}/${SAMPLE}/eukarya_${SAMPLE}.scaffolds.3k.fasta`                                | Tiara split: eukarya contigs (≥3k)                                              |
| `${OUTPUT_DIR}/${SAMPLE}/mitochondrion_${SAMPLE}.scaffolds.3k.fasta`                          | Tiara split: mitochondrion contigs (≥3k)                                        |
| `${OUTPUT_DIR}/${SAMPLE}/plastid_${SAMPLE}.scaffolds.3k.fasta`                                | Tiara split: plastid contigs (≥3k)                                              |
| `${OUTPUT_DIR}/${SAMPLE}/archaea_${SAMPLE}.scaffolds.3k.fasta`                                | Tiara split: archaea contigs (≥3k)                                              |
| `${OUTPUT_DIR}/${SAMPLE}/bacteria_${SAMPLE}.scaffolds.3k.fasta`                               | Tiara split: bacteria contigs (≥3k)                                             |
| `${OUTPUT_DIR}/${SAMPLE}/prokarya_${SAMPLE}.scaffolds.3k.fasta`                               | Tiara split: prokarya contigs (≥3k)                                             |
| `${OUTPUT_DIR}/${SAMPLE}/unknown_${SAMPLE}.scaffolds.3k.fasta`                                | Tiara split: unknown contigs (≥3k)                                              |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.tiara_3k.euk.fasta`                                        | Merged Tiara “3k euk pool” (euk+mito+plastid)                                   |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.out500.txt`                                                | Tiara classification report for small contigs (500-999)                         |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.out1000.txt`                                               | Tiara classification report for medium contigs (≥1000-3k)                       |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.tiara_merged.euk.fasta`                                    | Tiara-merged euk contigs from all tiers                                         |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta`                  | Tiara-merged non-euk contigs from small+medium bins (S500+S1000)                |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.kaiju-greedy.tiara_merged_small_contigs.non-euk.fasta.out` | Kaiju greedy output on Tiara small+medium non-euk contigs                       |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}_tiara_small_noeuk.names`                                   | Same as above but with taxon names added                                        |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.euk_contigs_list.txt`                                      | List of contig IDs rescued as Eukaryota from small+medium non-euk pool          |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.tiara_merged_small_contigs_kaiju_euk.fasta`                | FASTA of rescued small+medium euk contigs (from Kaiju)                          |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.01_tiara_kaiju_merged.euk.fasta**`                       | **(01)** Tiara euks (≥3k) + Kaiju-rescued small+medium euks merged              |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.tiara_kaiju_merged.euk.out`                                | Kaiju greedy output on file (01).                                               |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}_merged-euk.names`                                          | Kaiju greedy output with taxon names on file (01) (for filtering)               |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.01_kaiju_greedy_summary.tsv`                               | Kaiju phylum table for file (01)                                                |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.virus_contigs_list.txt`                                    | IDs flagged as Viruses in greedy pass of file (01)                              |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.prok_contigs_list_greedy.txt`                              | IDs flagged as Bacteria/Archaea in greedy pass of file (01)                     |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta**`               | **(02)** (01) minus viral contigs.                                              |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta**`        | **(03)** (02) minus prok contigs (greedy pass)                                  |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.tiara_kaiju_merged.euk-no-virus-noprok.out`                | Kaiju mem22 output on file (03)                                                 |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}_mem22.names`                                               | mem22 output with taxon names on file (03)                                      |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.prok_contigs_list_mem22.txt`                               | IDs flagged as prok by mem22 (cleanup list) on file (03)                        |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.04_tiara_kaiju_merged.euk-clean.fasta**`                 | **(04)** (03) cleaned using mem22 prok list                                     |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.05_tiara_kaiju_unclassified.fasta**`                     | **(05)** “Unclassified (U)” contigs extracted from greedy pass (from file (01)) |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta**`             | **(06)** Clean euk set with U contigs removed                                   |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.07_eukrep_balanced1000.euk.fasta**`                      | **(07)** EukRep-predicted euk contigs from (05), only contigs ≥1000 bp          |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta**`                  | **(08)** Final euk pool = (07) + (06)                                           |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta.out`                  | Kaiju greedy output on final pool (08)                                          |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.krona`                      | Krona text input for final pool (08)                                            |
| `${SUMMARY_DIR}/${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool_summary.tsv`                         | Final Kaiju phylum table for (08) (moved to summary dir)                        |
| `${SUMMARY_DIR}/${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.html`                                | Final Krona HTML for (08) (moved to summary dir)                                |
| `${OUTPUT_DIR}/${SAMPLE}/**${SAMPLE}.09_euk_pool_only_${SLUG}.fasta**`                        | **(09, optional)** Taxonomy-filtered subset of (08) (only if enabled)           |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.kaiju-greedy.for_${SLUG}.out`                              | (optional) Kaiju greedy output used to create (09)                              |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.kaiju-greedy.for_${SLUG}.krona`                            | (optional) Krona text input for the subset run                                  |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.kaiju-greedy.for_${SLUG}.html`                             | (optional) Krona HTML for the subset run                                        |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.for_${SLUG}.names`                                         | (optional) Subset run with taxon names                                          |
| `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.${SLUG}_contigs_list.txt`                                  | (optional) Contig IDs that match `TAXON_FILTERS`.                               |
| ```${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.10_final_prok_pool.fasta```                              | (optional) Prokaryote pool recovered during the pipeline                        |

On the STATS file you find:

| File                                        | Meaning                                                                           |
| ------------------------------------------- | --------------------------------------------------------------------------------- |
| `${STATS_DIR}/${SAMPLE}.pipeline.stats.tsv` | One row per checkpoint FASTA: contig counts/length stats (from `seqkit stats -a`) |

| FASTA checkpoint that is measured for ${SAMPLE}.pipeline.stats.tsv` | Meaning                                                     | Kept by the pipeline? |
| ------------------------------------------------------------------- | ----------------------------------------------------------- | --------------------- |
| `${SAMPLE}.tiara_3k.euk.fasta`                                      | Tiara euk pool from ≥3k tier                                | **YES**               |
| `${SAMPLE}.scaffolds.S500.fasta`                                    | Contigs binned to 500–999 bp (input of S500 bin)            | **NO**                |
| `${SAMPLE}.tiara_S500.euk.fasta`                                    | Tiara euk pool from S500 bin                                | **NO**                |
| `${SAMPLE}.tiara_S500.non-euk.fasta`                                | Tiara non-euk pool from S500 bin                            | **NO**                |
| `${SAMPLE}.scaffolds.S1000.fasta`                                   | Contigs binned to 1000–2999 bp (S1000 input bin)            | **NO**                |
| `${SAMPLE}.tiara_S1000.euk.fasta`                                   | Tiara euk pool from S1000 bin                               | **NO**                |
| `${SAMPLE}.tiara_S1000.non-euk.fasta`                               | Tiara non-euk pool from S1000 bin                           | **NO**                |
| `${SAMPLE}.tiara_merged.euk.fasta`                                  | Tiara euks merged across tiers                              | **YES**               |
| `${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta`                | S500+S1000 bins non-euks merged                             | **YES**               |
| **`${SAMPLE}.01_tiara_kaiju_merged.euk.fasta`**                     | **(01)** Tiara ≥3k euks + Kaiju-rescued S500+S1000 euks     | **YES**               |
| **`${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta`**             | **(02)** (01) without viral contigs                         | **YES**               |
| **`${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta`**      | **(03)** (02) without prok contigs (greedy pass)            | **YES**               |
| **`${SAMPLE}.04_tiara_kaiju_merged.euk-clean.fasta`**               | **(04)** (03) cleaned with mem22 prok list                  | **YES**               |
| **`${SAMPLE}.05_tiara_kaiju_unclassified.fasta`**                   | **(05)** Unclassified contigs extracted from greedy         | **YES**               |
| **`${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta`**           | **(06)** Clean euks with unclassified removed               | **YES**               |
| **`${SAMPLE}.07_eukrep_balanced1000.euk.fasta`**                    | **(07)** EukRep euks predicted from unclassified (≥1000 bp) | **YES**               |
| **`${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta`**                | **(08)** Final euk pool                                     | **YES**               |
| **`${SAMPLE}.09_euk_pool_only_${SLUG}.fasta`**                      | **(09, optional)** Taxonomy-filtered subset of (08)         | **YES (if enabled)**  |
| **```${SAMPLE}.10_final_prok_pool.fasta```**                        | **(10, optional)** Prok pool recovered during the pipeline  | **YES (if enabled)**  |
#### Useful downstream files for custom taxonomic summaries

In addition to the final FASTA output, some of the most useful files for downstream analyses are the **Kaiju classification outputs associated with the final eukaryotic pool**:

- `${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta.out`  
    Kaiju output for the final eukaryotic pool (`08`). This file can be used for downstream summarization at different taxonomic ranks (as it was done for `${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool_summary.tsv`) and to recover contigs belonging to specific taxonomic groups. Please refer to Kaiju manual for instructions.
    
- `${SUMMARY_DIR}/${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.html`  
    Krona HTML file for interactive exploration of the taxonomy assigned to the final pool.

## 7) Notes & troubleshooting

**Absolute-path env (no conda activation needed):**

`microEUKscope.sbatch` prepends `${ENV_PREFIX}/bin` to `PATH` and (optionally) `${ENV_PREFIX}/lib` to `LD_LIBRARY_PATH`. This avoids conda activate in non-interactive shells.

### 7.1 “command not found” (tiara/kaiju/seqkit/ktImportText)

Most common cause: `ENV_PREFIX` wrong or PATH not updated.

Ensure `ENV_PREFIX` is set in `config.env` and `${ENV_PREFIX}/bin` contains tiara, kaiju, seqkit, ktImportText, etc.
### 7.2 Kaiju DB errors

`KAIJU_DB_DIR` must contain:

- the Kaiju index `*.fmi`
    
- taxonomy files `nodes.dmp` and `names.dmp`
    
### 7.3 “No samples picked up”

- `SAMPLE_LIST` path wrong, or file empty

- `SAMPLE_LIST` must exist and contain one non-empty sample ID per line.


## License

microEUKscope is released under the MIT License (see `LICENSE`).

## Third-party software

This pipeline calls external tools including (but not limited to) Kaiju, Tiara, EukRep, and SeqKit.  
Those tools are **not** distributed with this repository and remain licensed by their respective authors under their own licenses.  
Please install and cite them according to their official documentation.

## Citation

If you use **microEUKscope** in your work, please cite:

- <YOUR NAME>, <COAUTHORS>. *microEUKscope: <short description>*. (2026). GitHub repository: <REPO URL>.  
  DOI: <ZENODO DOI or journal DOI when available>

In addition, please cite the third-party tools used by this pipeline (e.g., Kaiju, Tiara, EukRep) according to their respective documentation.







