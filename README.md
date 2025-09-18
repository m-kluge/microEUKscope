# microEUKscope

A pipeline to extract, curate, and summarize **eukaryotic contigs** from metagenomic assemblies using **Tiara → Kaiju → EukRep**, with per-sample stats, and Krona HTML summaries.

**SLURM-ready**: job array over `SAMPLE_LIST`; also runnable locally without SLURM.

**Note on compatibility**: EukRep requires **scikit-learn 0.23.x** (the model pickle depends on it). The provided environment is pinned accordingly.

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

### 3) Configure
```bash
cp config-example.env config.env
# edit config.env: CONTIGS_DIR, KAIJU_DB_DIR, PROJECT_DIR, etc.
```

### 4) Sample list

Create a plaintext file (default name: sample_list) with one sample ID per line, no header. If you use a different filename, set SAMPLE_LIST=/path/to/list in config.env.

```nginx
Sample1
Sample2
Sample3
```

## Running

### A) SLURM (array over all samples)
```bash
chmod +x submit_slurm.sh microEUKscope.sbatch microEUKscope_core.sh
bash submit_slurm.sh
```
Array size = number of lines in SAMPLE_LIST.
SLURM partition/time/cpus/memory are read from config.env.

### B) Local (no SLURM)

All samples: 
```bash
# mimic the sbatch environment used in microEUKscope.sbatch
source config.env
export PATH="${ENV_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${ENV_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

bash microEUKscope_core.sh
```

Single sample (e.g., 3rd in SAMPLE_LIST) without SLURM:
```bash
source config.env
export PATH="${ENV_PREFIX}/bin:${PATH}"

SLURM_ARRAY_TASK_ID=3 bash microEUKscope_core.sh
```

Single named sample using a one-line temp list:
```bash
printf '%s\n' "Sample_TF-2587-GR7-5" > /tmp/one_sample.list
SAMPLE_LIST=/tmp/one_sample.list bash microEUKscope_core.sh
```

## Output

For each SAMPLE, the pipeline creates a **per-sample work dir**: ${OUTPUT_DIR}/${SAMPLE}/, cointaiing all intermediate FASTA files from Tiara/Kaiju/EukRep and Kaiju outputs.

The **final fasta file with eukaryotic contigs** is ${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta

A per-sample **run log** (${SAMPLE}.pipeline.run.log) is created. 

**Stats dir** ${STATS_DIR}/ with single concatenated stats file per sample: ${SAMPLE}.pipeline.stats.tsv — contains seqkit stats for each generated fasta file.

**Summary dir**: ${SUMMARY_DIR}/ with Krona HTML of the final euk pool (${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.html) and Kaiju summary TSV (${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool_summary.tsv)
