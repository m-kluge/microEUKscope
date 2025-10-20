# How to run microEUKscope

This guide shows three ways to run the **microEUKscope** pipeline:

- **A)** SLURM manually with your own `sbatch` flags (also submits an **array**, one task per sample)
- **B)** SLURM using the provided *submit helper* 
- **C)** Locally, without SLURM (sequential over samples)

---

## One-time setup: install the environment (absolute path recommended)
```bash
# choose a fixed install location
ENV_PREFIX="/abs/path/to/conda/envs/microEUKscope"
conda env create -p "$ENV_PREFIX" -f environment.yml
```

## Create & edit your config file

Use the config-example.env as a template and edit accordingly.

```bash
cp config-example.env config.env
```

**Edit in config.env all paths to input files:**

CONTIGS_DIR=/abs/path/to/contigs

PROJECT_DIR=/abs/path/to/project_root

KAIJU_DB_DIR=/abs/path/to/kaiju_db   # contains *.fmi + nodes.dmp + names.dmp

**Inform the absolute path for the conda env for microEUKscope:**

ENV_PREFIX=/abs/path/to/conda/envs/microEUKscope

**Kaiju and TIARA parameters can be changed if desired.**

**An additional subset of contigs can be generated based on a desired taxa:**

DO_TAXON_SUBSET=1  

TAXON_FILTERS="Fungi"     #based on how the taxa appears on Kaiju output files

**There are optional SLURM knobs for a helper script, if desired:**

PIPELINE_PARTITION, PIPELINE_ACCOUNT, PIPELINE_CPUS, PIPELINE_TIME, etc.

## Prepare the sample list

Create a plaintext file (default name: sample_list) with one sample ID per line, no header. If you use a different filename, set SAMPLE_LIST=/path/to/list in config.env.

```nginx
Sample1
Sample2
Sample3
```

## Run the pipeline

### Option A) Run on SLURM manually (no helper script)

You pass sbatch flags yourself, according to your cluster. The example below also submits an array (one task per sample):

```bash
# ensure config.env has ENV_PREFIX set to your absolute conda prefix
sbatch \
  -p core \
  -A your-account \
  -t 20:00:00 \
  -J microEUKscope \
  --array=1-$(grep -cve '^\s*$' sample_list) \
  --ntasks=1 --cpus-per-task=20 \
  --chdir "$(pwd)" \
  microEUKscope.sbatch
  ```

**Variants:**

Single sample (e.g., 7th in the list): --array=7-7

First 10 samples: --array=1-10

If you omit --array, the job will run once and the core script will iterate all samples sequentially (not typical for SLURM).


### Option B) If useful, run on SLURM using the helper script

Submits a single array job with one task per sample (based on SAMPLE_LIST):

```bash
bash submit_slurm.sh
```

What happens:

Reads SLURM settings from config.env (e.g., PIPELINE_PARTITION, PIPELINE_CPUS, …).

Counts samples in SAMPLE_LIST and submits --array=1-N.

Executes microEUKscope.sbatch, which sets up the env from ENV_PREFIX and runs microEUKscope_core.sh.

### Option C) Run locally (no SLURM)

Process all samples sequentially on your workstation/login node:

```bash
source config.env
export PATH="${ENV_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${ENV_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

bash microEUKscope_core.sh
```

Process a single sample locally:

```bash
printf '%s\n' "Sample_A" > /tmp/one_sample.list
SAMPLE_LIST=/tmp/one_sample.list bash microEUKscope_core.sh
```

## Outputs (per sample):

For each SAMPLE, the pipeline creates a **per-sample work dir**: ${OUTPUT_DIR}/${SAMPLE}/, cointaiing all intermediate FASTA files from Tiara/Kaiju/EukRep and Kaiju outputs. The **final fasta file with microeukaryotic contigs** is ${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta 

${OUTPUT_DIR}/${SAMPLE}/
  ${SAMPLE}.pipeline.run.log
  08_tiara_kaiju_eukrep.euk-pool.fasta #final pool of contigs classified as microeukariotes
  
A per-sample **run log** (${SAMPLE}.pipeline.run.log) is created. 

**Stats dir** ${STATS_DIR}/ with single concatenated stats file per sample: ${SAMPLE}.pipeline.stats.tsv — contains seqkit stats for each generated fasta file. 

**Summary dir**: ${SUMMARY_DIR}/ with Krona HTML of the final euk pool (${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.html) and Kaiju summary TSV (${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool_summary.tsv)

### Notes & troubleshooting

Absolute-path env (no activation needed):
microEUKscope.sbatch prepends ${ENV_PREFIX}/bin to PATH and (optionally) ${ENV_PREFIX}/lib to LD_LIBRARY_PATH. This avoids conda activate in non-interactive shells.

Required tools not found
Ensure ENV_PREFIX is set in config.env and ${ENV_PREFIX}/bin contains tiara, kaiju, seqkit, ktImportText, etc.

Kaiju DB errors
KAIJU_DB_DIR must contain the Kaiju index .fmi and taxonomy files nodes.dmp + names.dmp.

No samples picked up
SAMPLE_LIST must exist and contain one non-empty sample ID per line.

Compatibility
EukRep requires scikit-learn 0.23.x; the provided environment files are pinned accordingly.
