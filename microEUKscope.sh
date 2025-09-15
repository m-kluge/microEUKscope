#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Load user config (edit config.env, not this script)
###############################################################################
if [[ -f "config.env" ]]; then
  # shellcheck disable=SC1091
  source config.env
else
  echo "[info] config.env not found; using built-in defaults. Create and edit config.env to customize." >&2
fi

###############################################################################
# DEFAULTS (only used if not set in config.env)
###############################################################################
# Samples
export SAMPLE_LIST="${SAMPLE_LIST:-sample_list}"  # one SAMPLE id per line, no header

# Directories / paths
export PROJECT_DIR="${PROJECT_DIR:-/path/to/project}"
export CONTIGS_DIR="${CONTIGS_DIR:-/path/to/min500}"     # contains files like ${SAMPLE}*.fa|*.fasta[.gz]
export OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}" # per-sample working
export STATS_DIR="${STATS_DIR:-${PROJECT_DIR}/stats}"    # (not used for writes anymore)
export SUMMARY_DIR="${SUMMARY_DIR:-${OUTPUT_DIR}/summary}"  # all stats + krona, etc.

# Tools (from the conda/mamba env PATH)
export SEQKIT_BIN="${SEQKIT_BIN:-seqkit}"

# Tiara
export TIARA_THREADS="${TIARA_THREADS:-20}"
export TIARA_TF="${TIARA_TF:-all}"
export BIN_S500_MIN="${BIN_S500_MIN:-500}";   export BIN_S500_MAX="${BIN_S500_MAX:-999}"
export BIN_S1000_MIN="${BIN_S1000_MIN:-1000}"; export BIN_S1000_MAX="${BIN_S1000_MAX:-2999}"
export BIN_3K_MIN="${BIN_3K_MIN:-3000}"

# Kaiju DB (edit in config.env)
export KAIJU_DB_DIR="${KAIJU_DB_DIR:-/path/to/kaiju_db}"
export KAIJU_NODES="${KAIJU_NODES:-${KAIJU_DB_DIR}/nodes.dmp}"
export KAIJU_NAMES="${KAIJU_NAMES:-${KAIJU_DB_DIR}/names.dmp}"
export KAIJU_FMI="${KAIJU_FMI:-${KAIJU_DB_DIR}/JGI_myco_phyco_oct22_nr_euk_jan23.fmi}"

# Kaiju params
export KAIJU_THREADS="${KAIJU_THREADS:-20}"
export KAIJU_GREEDY_E="${KAIJU_GREEDY_E:-5}"
export KAIJU_GREEDY_S="${KAIJU_GREEDY_S:-75}"

# Optional taxa subset on final euk pool
export DO_TAXON_SUBSET="${DO_TAXON_SUBSET:-0}"    # 1=on, 0=off
export TAXON_FILTERS="${TAXON_FILTERS:-Fungi}"    # e.g. "Fungi Oomycota"
export CASE_INSENSITIVE="${CASE_INSENSITIVE:-0}"  # 0=case-sensitive (default), set 1 for grep -i

# SLURM (single-job array) — defaults; users can override in config.env
PIPELINE_PARTITION="${PIPELINE_PARTITION:-node}"   # cluster partition/queue
PIPELINE_CPUS="${PIPELINE_CPUS:-20}"               # CPUs for tiara/kaiju/eukrep
PIPELINE_TIME="${PIPELINE_TIME:-12:00:00}"         # wall time per array task
PIPELINE_ACCOUNT="${PIPELINE_ACCOUNT:-your-slurm-account}"
# Optional (leave empty if unused)
PIPELINE_CONSTRAINT="${PIPELINE_CONSTRAINT:-}"     # e.g. mem256GB
PIPELINE_MEM="${PIPELINE_MEM:-}"                   # e.g. 220G
PIPELINE_NODES="${PIPELINE_NODES:-}"               # e.g. 1
PIPELINE_NTASKS_PER_NODE="${PIPELINE_NTASKS_PER_NODE:-}" # e.g. 1
PIPELINE_EXCLUSIVE="${PIPELINE_EXCLUSIVE:-}"       # set to 1/yes/true to request --exclusive
PIPELINE_MAIL_TYPE="${PIPELINE_MAIL_TYPE:-}"       # e.g. ALL, BEGIN, END, FAIL
PIPELINE_MAIL_USER="${PIPELINE_MAIL_USER:-}"       # your@email

# Ensure output dirs exist
mkdir -p "${OUTPUT_DIR}" "${SUMMARY_DIR}"

###############################################################################
# Portable env activation snippet (exported so the job can eval it)
# (Looks for 'microEUKscope' env by default; override with CONDA_ENV_ALL)
###############################################################################
read -r -d '' _ACTIVATE_ENV_SNIPPET <<"__ACTIVATE__"
# --- load site modules if requested (e.g. PDC & miniconda on Dardel) ---
if [[ -n "${MODULE_LOADS:-}" ]]; then
  for _m in ${MODULE_LOADS}; do
    module load "$_m"
  done
fi

# --- portable conda/micromamba activation (supports name or prefix path) ---
ENV_NAME="${CONDA_ENV_ALL:-microEUKscope}"
if [[ -z "${CONDA_DEFAULT_ENV:-}" || "${CONDA_DEFAULT_ENV}" != "${ENV_NAME}" ]]; then
  if command -v conda >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "${ENV_NAME}" || {
      echo "ERROR: conda env '${ENV_NAME}' not found. Create it from environment.yml." >&2; exit 1;
    }
  elif command -v micromamba >/dev/null 2>&1; then
    eval "$(micromamba shell hook -s bash)"
    micromamba activate "${ENV_NAME}" || {
      echo "ERROR: micromamba env '${ENV_NAME}' not found. Create it from environment.yml." >&2; exit 1;
    }
  else
    echo "ERROR: conda/micromamba not found. Install Miniconda/Mambaforge or Micromamba first." >&2
    exit 1
  fi
fi
__ACTIVATE__
export ACTIVATE_ENV_SNIPPET="${_ACTIVATE_ENV_SNIPPET}"

# Normalize EXCLUSIVE flag to either "--exclusive" or empty (avoid set -u issues)
_EXCLUSIVE_FLAG=""
if [[ "${PIPELINE_EXCLUSIVE:-}" =~ ^(1|yes|true|TRUE|Yes)$ ]]; then
  _EXCLUSIVE_FLAG="--exclusive"
fi

###############################################################################
# SUBMIT SINGLE JOB ARRAY (Tiara + Kaiju/EukRep in one job)
###############################################################################
sbatch \
  -p "$PIPELINE_PARTITION" \
  -A "$PIPELINE_ACCOUNT" \
  -t "$PIPELINE_TIME" \
  -J "microEUKscope" \
  --array="1-$(wc -l < "$SAMPLE_LIST")" \
  --ntasks=1 \
  --cpus-per-task="$PIPELINE_CPUS" \
  ${PIPELINE_NODES:+--nodes="$PIPELINE_NODES"} \
  ${PIPELINE_NTASKS_PER_NODE:+--ntasks-per-node="$PIPELINE_NTASKS_PER_NODE"} \
  ${_EXCLUSIVE_FLAG:+${_EXCLUSIVE_FLAG}} \
  ${PIPELINE_CONSTRAINT:+-C "$PIPELINE_CONSTRAINT"} \
  ${PIPELINE_MEM:+--mem="$PIPELINE_MEM"} \
  ${PIPELINE_MAIL_TYPE:+--mail-type="$PIPELINE_MAIL_TYPE"} \
  ${PIPELINE_MAIL_USER:+--mail-user="$PIPELINE_MAIL_USER"} \
  --export=ALL <<'EOF_JOB'
#!/bin/bash -l
set -euo pipefail

# Activate the conda/mamba env (defined in parent script)
eval "$ACTIVATE_ENV_SNIPPET"

# Avoid hidden oversubscription by math/OpenMP libs
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

# ---- helper: safe_cat with logging & .gz support
safe_cat() {
  # Usage: safe_cat OUT FILE [FILE ...]
  local out="$1"; shift
  : > "$out"
  local ok=0 miss=0
  for f in "$@"; do
    if [[ -s "$f" ]]; then
      if [[ "$f" == *.gz ]]; then
        gzip -cd -- "$f" >> "$out"
      else
        cat -- "$f" >> "$out"
      fi
      echo "[safe_cat] appended $(basename "$f")" >&2
      ((ok++))
    else
      echo "[safe_cat] SKIP missing/empty $(basename "$f")" >&2
      ((miss++))
    fi
  done
  if [[ $ok -eq 0 ]]; then
    echo "[safe_cat] WARNING: nothing concatenated into $(basename "$out")" >&2
  else
    echo "[safe_cat] done: $(basename "$out") (appended=$ok skipped=$miss)" >&2
  fi
}

# Resolve sample
SAMPLE="$(sed -n "${SLURM_ARRAY_TASK_ID}p" "${SAMPLE_LIST}")"
[[ -n "${SAMPLE}" ]] || { echo "Empty SAMPLE for task ${SLURM_ARRAY_TASK_ID}"; exit 1; }

# Prepare dirs & logging
SAMPLE_DIR="${OUTPUT_DIR}/${SAMPLE}"
mkdir -p "${SAMPLE_DIR}" "${SUMMARY_DIR}"
exec > >(tee -a "${SAMPLE_DIR}/${SAMPLE}.pipeline.run.log") 2>&1
echo "[`date '+%F %T'`] Start ${SAMPLE}"

cd "${SAMPLE_DIR}"

# ---- choose input contigs: first match of ${SAMPLE}*.fa|*.fasta[.gz] (case-insensitive), warn if >1
choose_input_contigs() {
  local canon="${SAMPLE}.contigs_input.fa"

  # find matches
  mapfile -d '' candidates < <(find -L "${CONTIGS_DIR}" -maxdepth 1 -type f \
    -regextype posix-extended \
    -iregex ".*/${SAMPLE}.*\.(fa|fasta)(\.gz)?$" -print0 | sort -z -f)

  if (( ${#candidates[@]} == 0 )); then
    echo "[input] No contigs for ${SAMPLE} in ${CONTIGS_DIR} matching '${SAMPLE}*.fa|*.fasta[.gz]'." >&2
    exit 1
  fi
  if (( ${#candidates[@]} > 1 )); then
    echo "[input] Multiple inputs found; picking the first (sorted, case-insensitive). Others listed for awareness:" >&2
    printf '  - %s\n' "${candidates[@]}" >&2
  fi

  local chosen="${candidates[0]}"
  if [[ "$chosen" == *.gz ]]; then
    gzip -cd -- "$chosen" > "$canon"
  else
    cp -f -- "$chosen" "$canon"
  fi
  SRC_CONTIGS="$canon"
  echo "[input] using $(basename "$chosen")  →  ${canon}" >&2
}
choose_input_contigs

###############################################################################
# TIARA
###############################################################################
echo "[`date '+%F %T'`] Tiara 3k on ${SRC_CONTIGS}"
tiara -i "${SRC_CONTIGS}" -o "${SAMPLE}.out3000.txt" -t "${TIARA_THREADS}" -m "${BIN_3K_MIN}" --tf "${TIARA_TF}"

# Rename Tiara class splits from *_contigs_input.fa -> *_${SAMPLE}.scaffolds.3k.fasta
for cls in eukarya mitochondrion plastid archaea bacteria prokarya unknown; do
  src="${cls}_${SAMPLE}.contigs_input.fa"
  dst="${cls}_${SAMPLE}.scaffolds.3k.fasta"
  if [[ -s "$src" ]]; then
    mv -f -- "$src" "$dst"; echo "[rename] $src -> $dst"
  else
    echo "[rename] skip missing/empty $src"
  fi
done

# Build the 3k euk pool from euk/mito/plastid
safe_cat "${SAMPLE}.tiara_3k.euk.fasta" \
  "eukarya_${SAMPLE}.scaffolds.3k.fasta" \
  "mitochondrion_${SAMPLE}.scaffolds.3k.fasta" \
  "plastid_${SAMPLE}.scaffolds.3k.fasta"

"${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_3k.euk.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.3k_tiara.scaffolds.stats.tsv"

# S500 bin
echo "[`date '+%F %T'`] Build S500 bin"
"${SEQKIT_BIN}" seq -m "${BIN_S500_MIN}" -M "${BIN_S500_MAX}" "${SRC_CONTIGS}" > "${SAMPLE}.scaffolds.S500.fasta"
"${SEQKIT_BIN}" stats -a "${SAMPLE}.scaffolds.S500.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.S500.scaffolds.stats.tsv"

echo "[`date '+%F %T'`] Tiara S500"
tiara -i "${SAMPLE}.scaffolds.S500.fasta" -o "${SAMPLE}.out500.txt" -t "${TIARA_THREADS}" -m "${BIN_S500_MIN}" --tf "${TIARA_TF}"

safe_cat "${SAMPLE}.tiara_S500.euk.fasta" \
  "eukarya_${SAMPLE}.scaffolds.S500.fasta" \
  "mitochondrion_${SAMPLE}.scaffolds.S500.fasta" \
  "plastid_${SAMPLE}.scaffolds.S500.fasta"
"${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S500.euk.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.S500_euk.stats.tsv"

safe_cat "${SAMPLE}.tiara_S500.non-euk.fasta" \
  "archaea_${SAMPLE}.scaffolds.S500.fasta" \
  "bacteria_${SAMPLE}.scaffolds.S500.fasta" \
  "prokarya_${SAMPLE}.scaffolds.S500.fasta" \
  "unknown_${SAMPLE}.scaffolds.S500.fasta"
"${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S500.non-euk.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.S500_non-euk.stats.tsv"

rm -f "${SAMPLE}.scaffolds.S500.fasta" \
      "eukarya_${SAMPLE}.scaffolds.S500.fasta" "mitochondrion_${SAMPLE}.scaffolds.S500.fasta" "plastid_${SAMPLE}.scaffolds.S500.fasta" \
      "archaea_${SAMPLE}.scaffolds.S500.fasta" "bacteria_${SAMPLE}.scaffolds.S500.fasta" "prokarya_${SAMPLE}.scaffolds.S500.fasta" "unknown_${SAMPLE}.scaffolds.S500.fasta"

# S1000 bin
echo "[`date '+%F %T'`] Build S1000 bin"
"${SEQKIT_BIN}" seq -m "${BIN_S1000_MIN}" -M "${BIN_S1000_MAX}" "${SRC_CONTIGS}" > "${SAMPLE}.scaffolds.S1000.fasta"
"${SEQKIT_BIN}" stats -a "${SAMPLE}.scaffolds.S1000.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.S1000.scaffolds.stats.tsv"

echo "[`date '+%F %T'`] Tiara S1000"
tiara -i "${SAMPLE}.scaffolds.S1000.fasta" -o "${SAMPLE}.out1000.txt" -t "${TIARA_THREADS}" -m "${BIN_S1000_MIN}" --tf "${TIARA_TF}"

safe_cat "${SAMPLE}.tiara_S1000.euk.fasta" \
  "eukarya_${SAMPLE}.scaffolds.S1000.fasta" \
  "mitochondrion_${SAMPLE}.scaffolds.S1000.fasta" \
  "plastid_${SAMPLE}.scaffolds.S1000.fasta"
"${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S1000.euk.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.S1000_euk.stats.tsv"

safe_cat "${SAMPLE}.tiara_S1000.non-euk.fasta" \
  "archaea_${SAMPLE}.scaffolds.S1000.fasta" \
  "bacteria_${SAMPLE}.scaffolds.S1000.fasta" \
  "prokarya_${SAMPLE}.scaffolds.S1000.fasta" \
  "unknown_${SAMPLE}.scaffolds.S1000.fasta"
"${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S1000.non-euk.fasta" | sed -e '1d' > "${SUMMARY_DIR}/${SAMPLE}.S1000_non-euk.stats.tsv"

rm -f "${SAMPLE}.scaffolds.S1000.fasta" \
      "eukarya_${SAMPLE}.scaffolds.S1000.fasta" "mitochondrion_${SAMPLE}.scaffolds.S1000.fasta" "plastid_${SAMPLE}.scaffolds.S1000.fasta" \
      "archaea_${SAMPLE}.scaffolds.S1000.fasta" "bacteria_${SAMPLE}.scaffolds.S1000.fasta" "prokarya_${SAMPLE}.scaffolds.S1000.fasta" "unknown_${SAMPLE}.scaffolds.S1000.fasta"

# Merge outputs
echo "[`date '+%F %T'`] Merge euk/non-euk"
safe_cat "${SAMPLE}.tiara_merged.euk.fasta" \
  "${SAMPLE}.tiara_S500.euk.fasta" \
  "${SAMPLE}.tiara_S1000.euk.fasta" \
  "${SAMPLE}.tiara_3k.euk.fasta"

safe_cat "${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta" \
  "${SAMPLE}.tiara_S500.non-euk.fasta" \
  "${SAMPLE}.tiara_S1000.non-euk.fasta"

rm -f "${SAMPLE}.tiara_S500.euk.fasta" "${SAMPLE}.tiara_S1000.euk.fasta" \
      "${SAMPLE}.tiara_S500.non-euk.fasta" "${SAMPLE}.tiara_S1000.non-euk.fasta"

###############################################################################
# KAIJU + EUKREP
###############################################################################
echo "[`date '+%F %T'`] Kaiju (rescues & cleanup) + EukRep"

# 1) Kaiju greedy on small non-euk
kaiju -z "${KAIJU_THREADS}" -t "${KAIJU_NODES}" -f "${KAIJU_FMI}" \
  -i "${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta" \
  -e "${KAIJU_GREEDY_E}" -s "${KAIJU_GREEDY_S}" \
  -o "${SAMPLE}.kaiju-greedy.tiara_merged_small_contigs.non-euk.fasta.out"

kaiju2krona -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
  -i "${SAMPLE}.kaiju-greedy.tiara_merged_small_contigs.non-euk.fasta.out" \
  -o "${SAMPLE}.kaiju_new_db_tiara_small_noeuk.krona"
ktImportText -o "${SAMPLE}_tiara_small_noeuk.html" "${SAMPLE}.kaiju_new_db_tiara_small_noeuk.krona"

kaiju-addTaxonNames -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
  -i "${SAMPLE}.kaiju-greedy.tiara_merged_small_contigs.non-euk.fasta.out" -u -p \
  -o "${SAMPLE}_tiara_small_noeuk.names"

grep "Eukaryota" "${SAMPLE}_tiara_small_noeuk.names" > "${SAMPLE}.euk_contigs" || true
cut -f 2 "${SAMPLE}.euk_contigs" > "${SAMPLE}.euk_contigs_list.txt" || true
rm -f "${SAMPLE}.euk_contigs"

"${SEQKIT_BIN}" grep -f "${SAMPLE}.euk_contigs_list.txt" \
  "${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta" \
  > "${SAMPLE}.tiara_merged_small_contigs_kaiju_euk.fasta" || true

# Merge the kaiju-rescued small euks with the Tiara-merged euks
safe_cat "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" \
  "${SAMPLE}.tiara_merged_small_contigs_kaiju_euk.fasta" \
  "${SAMPLE}.tiara_merged.euk.fasta"

# 2) Kaiju greedy on merged euk; remove viruses/prok
kaiju -z "${KAIJU_THREADS}" -t "${KAIJU_NODES}" -f "${KAIJU_FMI}" \
  -i "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" \
  -e "${KAIJU_GREEDY_E}" -s "${KAIJU_GREEDY_S}" \
  -o "${SAMPLE}.tiara_kaiju_merged.euk.out"

kaiju2krona -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
  -i "${SAMPLE}.tiara_kaiju_merged.euk.out" \
  -o "${SAMPLE}.kaiju_new_db_merged-euk.krona"
ktImportText -o "${SAMPLE}.kaiju_new_db_merged-euk.html" "${SAMPLE}.kaiju_new_db_merged-euk.krona"

kaiju-addTaxonNames -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
  -i "${SAMPLE}.tiara_kaiju_merged.euk.out" -u -p \
  -o "${SAMPLE}_merged-euk.names"

kaiju2table -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" -r phylum -p \
  -o "${SAMPLE}.kaiju_new_db_greedy_summary.tsv" \
  "${SAMPLE}.tiara_kaiju_merged.euk.out"

# Move Kaiju summary artifacts to the global SUMMARY_DIR
mv -f "${SAMPLE}.kaiju_new_db_greedy_summary.tsv" "${SUMMARY_DIR}/"
mv -f "${SAMPLE}.kaiju_new_db_merged-euk.html" "${SUMMARY_DIR}/"

grep "Viruses"  "${SAMPLE}_merged-euk.names" > "${SAMPLE}.virus_contigs_greedy" || true
grep "Bacteria" "${SAMPLE}_merged-euk.names" > "${SAMPLE}.prok1_contigs_greedy" || true
grep "Archaea"  "${SAMPLE}_merged-euk.names" > "${SAMPLE}.prok2_contigs_greedy" || true
cat "${SAMPLE}.prok1_contigs_greedy" "${SAMPLE}.prok2_contigs_greedy" > "${SAMPLE}.prok_contigs_greedy" || true
grep -P "\tU\t" "${SAMPLE}.tiara_kaiju_merged.euk.out" | cut -f 2 > "${SAMPLE}.unclassified_contigs_greedy" || true

cut -f 2 "${SAMPLE}.virus_contigs_greedy" > "${SAMPLE}.virus_contigs_list.txt" || true
cut -f 2 "${SAMPLE}.prok_contigs_greedy"  > "${SAMPLE}.prok_contigs_list_greedy.txt" || true
rm -f "${SAMPLE}.virus_contigs_greedy" "${SAMPLE}.prok_contigs_greedy" "${SAMPLE}.prok1_contigs_greedy" "${SAMPLE}.prok2_contigs_greedy"

"${SEQKIT_BIN}" grep -f "${SAMPLE}.virus_contigs_list.txt" --invert-match \
  "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" > "${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta"

"${SEQKIT_BIN}" grep -f "${SAMPLE}.prok_contigs_list_greedy.txt" --invert-match \
  "${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta" > "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta"

# 3) mem22 cleanup
kaiju -z "${KAIJU_THREADS}" -t "${KAIJU_NODES}" -f "${KAIJU_FMI}" \
  -i "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta" \
  -a mem -m 22 \
  -o "${SAMPLE}.tiara_kaiju_merged.euk-no-virus-noprok.out"

kaiju2krona -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
  -i "${SAMPLE}.tiara_kaiju_merged.euk-no-virus-noprok.out" \
  -o "${SAMPLE}.kaiju_new_db_mem22.krona"
ktImportText -o "${SAMPLE}_mem22.html" "${SAMPLE}.kaiju_new_db_mem22.krona"

kaiju-addTaxonNames -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
  -i "${SAMPLE}.tiara_kaiju_merged.euk-no-virus-noprok.out" -u -p \
  -o "${SAMPLE}_mem22.names"

grep "Bacteria" "${SAMPLE}_mem22.names" > "${SAMPLE}.prok1_contigs" || true
grep "Archaea"  "${SAMPLE}_mem22.names" > "${SAMPLE}.prok2_contigs" || true
cat "${SAMPLE}.prok1_contigs" "${SAMPLE}.prok2_contigs" > "${SAMPLE}.prok_contigs_mem22" || true
rm -f "${SAMPLE}.prok1_contigs" "${SAMPLE}.prok2_contigs"

cut -f 2 "${SAMPLE}.prok_contigs_mem22" > "${SAMPLE}.prok_contigs_list_mem22.txt" || true
rm -f "${SAMPLE}.prok_contigs_mem22"

"${SEQKIT_BIN}" grep -f "${SAMPLE}.prok_contigs_list_mem22.txt" --invert-match \
  "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta" > "${SAMPLE}.04_tiara_kaiju_merged.euk-clean.fasta"

"${SEQKIT_BIN}" grep -f "${SAMPLE}.unclassified_contigs_greedy" \
  "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta" > "${SAMPLE}.05_tiara_kaiju_unclassified.fasta"

"${SEQKIT_BIN}" grep -f "${SAMPLE}.unclassified_contigs_greedy" --invert-match \
  "${SAMPLE}.04_tiara_kaiju_merged.euk-clean.fasta" > "${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta"
rm -f "${SAMPLE}.unclassified_contigs_greedy"

# 4) EukRep on unclassified; merge with clean euk
EukRep -i "${SAMPLE}.05_tiara_kaiju_unclassified.fasta" -m balanced \
  -o "${SAMPLE}.07_eukrep_balanced1000.euk.fasta" --min 1000

safe_cat "${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta" \
  "${SAMPLE}.07_eukrep_balanced1000.euk.fasta" \
  "${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta"

# 5) OPTIONAL taxa subset with slug
if [[ "${DO_TAXON_SUBSET}" -eq 1 ]]; then
  echo "[`date '+%F %T'`] Taxon subset active: ${TAXON_FILTERS}"
  SLUG_RAW="${TAXON_FILTERS}"; SLUG="${SLUG_RAW// /_}"; SLUG="${SLUG//[^A-Za-z0-9_.-]/_}"

  kaiju -z "${KAIJU_THREADS}" -t "${KAIJU_NODES}" -f "${KAIJU_FMI}" \
    -i "${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta" \
    -e "${KAIJU_GREEDY_E}" -s "${KAIJU_GREEDY_S}" \
    -o "${SAMPLE}.kaiju-greedy.for_${SLUG}.out"

  kaiju2krona -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
    -i "${SAMPLE}.kaiju-greedy.for_${SLUG}.out" \
    -o "${SAMPLE}.kaiju-greedy.for_${SLUG}.krona"
  ktImportText -o "${SAMPLE}.kaiju-greedy.for_${SLUG}.html" "${SAMPLE}.kaiju-greedy.for_${SLUG}.krona"

  kaiju-addTaxonNames -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
    -i "${SAMPLE}.kaiju-greedy.for_${SLUG}.out" -u -p \
    -o "${SAMPLE}.for_${SLUG}.names"

  PATTERN="$(printf '%s|' ${TAXON_FILTERS})"; PATTERN="${PATTERN%|}"
  if [[ "${CASE_INSENSITIVE}" -eq 1 ]]; then
    grep -E -i "${PATTERN}" "${SAMPLE}.for_${SLUG}.names" > "${SAMPLE}.${SLUG}_contigs"
  else
    grep -E    "${PATTERN}" "${SAMPLE}.for_${SLUG}.names" > "${SAMPLE}.${SLUG}_contigs"
  fi
  cut -f 2 "${SAMPLE}.${SLUG}_contigs" > "${SAMPLE}.${SLUG}_contigs_list.txt"

  "${SEQKIT_BIN}" grep -f "${SAMPLE}.${SLUG}_contigs_list.txt" \
    "${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta" > "${SAMPLE}.09_euk_pool_only_${SLUG}.fasta"
  echo "[`date '+%F %T'`] Taxa subset saved as: ${SAMPLE}.09_euk_pool_only_${SLUG}.fasta"
fi

# ---- One-pass stats for ALL Kaiju/EukRep numbered FASTA (01..09) -> SUMMARY_DIR
echo "[`date '+%F %T'`] Writing seqkit stats for Kaiju/EukRep outputs (01..09) to SUMMARY_DIR"
shopt -s nullglob
for f in "${SAMPLE}."[0-9]*.fasta; do
  [[ -s "$f" ]] || continue
  bn="$(basename "$f")"                              # e.g., SAMPLE.03_tiara_...
  out="${SUMMARY_DIR}/${bn%.fasta}.stats.tsv"        # global summary folder
  "${SEQKIT_BIN}" stats -a "$f" | sed -e '1d' > "$out" || true
done
shopt -u nullglob

echo "[`date '+%F %T'`] DONE ${SAMPLE}"
EOF_JOB


