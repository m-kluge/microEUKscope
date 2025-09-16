#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Load user config (edit config.env, not this script)
###############################################################################

# Load config
if [[ -f "config.env" ]]; then
  # shellcheck disable=SC1091
  source config.env
else
  echo "[info] config.env not found; using built-in defaults." >&2
fi

###############################################################################
# DEFAULTS (only used if not set in config.env)
###############################################################################

# Samples
export SAMPLE_LIST="${SAMPLE_LIST:-sample_list}"

# Directories / paths
export CONTIGS_DIR="${CONTIGS_DIR:-/path/to/contigs}" # contains files like ${SAMPLE}*.fa|*.fasta[.gz]
export PROJECT_DIR="${PROJECT_DIR:-/path/to/project}"
export OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}" # per-sample working directory
export STATS_DIR="${STATS_DIR:-${PROJECT_DIR}/stats}"
export SUMMARY_DIR="${SUMMARY_DIR:-${OUTPUT_DIR}/summary}" # all stats + krona

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

# Optional step: taxa subset on final euk pool
export DO_TAXON_SUBSET="${DO_TAXON_SUBSET:-0}" # 1=on, 0=off
export TAXON_FILTERS="${TAXON_FILTERS:-Fungi}" # e.g. "Fungi"
export CASE_INSENSITIVE="${CASE_INSENSITIVE:-0}" # 0=case-sensitive (default), set 1 for grep -i

# Ensure output dirs exist
mkdir -p "${OUTPUT_DIR}" "${SUMMARY_DIR}" "${STATS_DIR}"

# Helpers: safe_cat with logging & .gz support
safe_cat() {
  local out="$1"; shift
  : > "$out"
  local ok=0
  for f in "$@"; do
    [[ -s "$f" ]] || continue
    if [[ "$f" == *.gz ]]; then gzip -cd -- "$f" >> "$out"; else cat -- "$f" >> "$out"; fi
    ((ok++))
  done
  [[ $ok -eq 0 ]] && echo "[safe_cat] WARNING: nothing written to $(basename "$out")" >&2
}

# ---- choose input contigs: first match of ${SAMPLE}*.fa|*.fasta[.gz], warn if >1
choose_input_contigs() {
  local sample="${1:?missing sample id}"
  local canon="${sample}.contigs_input.fa"
  local -a candidates=()

  mapfile -t candidates < <(
    find -L "${CONTIGS_DIR}" -maxdepth 1 -type f \
      \( -name "${sample}*.fa" -o -name "${sample}*.fa.gz" \
         -o -name "${sample}*.fasta" -o -name "${sample}*.fasta.gz" \) \
    | LC_ALL=C sort
  )

  (( ${#candidates[@]} >= 1 )) || { 
    echo "[input] No contigs for ${sample} in ${CONTIGS_DIR}" >&2
    return 1
  }

  if (( ${#candidates[@]} > 1 )); then
    echo "[input] Multiple inputs for ${sample}; using the first (case-sensitive sort):" >&2
    printf '  - %s\n' "${candidates[@]}" >&2
  fi

  local chosen="${candidates[0]}"
  if [[ "$chosen" == *.gz ]]; then
    gzip -cd -- "$chosen" > "$canon"
  else
    cp -f -- "$chosen" "$canon"
  fi
  echo "$canon"
}

process_sample() {
  local SAMPLE="$1"

  local SAMPLE_DIR="${OUTPUT_DIR}/${SAMPLE}"
  mkdir -p "${SAMPLE_DIR}"
  exec > >(tee -a "${SAMPLE_DIR}/${SAMPLE}.pipeline.run.log") 2>&1
  echo "[`date '+%F %T'`] Start ${SAMPLE}"
  cd "${SAMPLE_DIR}"

  # input
  local SRC_CONTIGS
  SRC_CONTIGS="$(choose_input_contigs "${SAMPLE}")" || exit 1
  echo "[input] using $(basename "$SRC_CONTIGS")"

  ########################
  # TIARA
  ########################
  echo "[`date '+%F %T'`] Tiara 3k"
  tiara -i "${SRC_CONTIGS}" -o "${SAMPLE}.out3000.txt" -t "${TIARA_THREADS}" -m "${BIN_3K_MIN}" --tf "${TIARA_TF}"

  # Rename Tiara class splits from *_contigs_input.fa -> *_${SAMPLE}.scaffolds.3k.fasta
  for cls in eukarya mitochondrion plastid archaea bacteria prokarya unknown; do
    src="${cls}_${SAMPLE}.contigs_input.fa"
    dst="${cls}_${SAMPLE}.scaffolds.3k.fasta"
    if [[ -s "$src" ]]; then
      mv -f -- "$src" "$dst" \
        && printf '[rename] %s -> %s\n' "$src" "$dst" \
        || { printf '[rename][WARN] failed: %s -> %s\n' "$src" "$dst" >&2; continue; }
    else
      printf '[rename] skip missing/empty %s\n' "$src"
    fi
  done

  # Build the 3k euk pool from euk/mito/plastid
  safe_cat "${SAMPLE}.tiara_3k.euk.fasta" \
    "eukarya_${SAMPLE}.scaffolds.3k.fasta" \
    "mitochondrion_${SAMPLE}.scaffolds.3k.fasta" \
    "plastid_${SAMPLE}.scaffolds.3k.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_3k.euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.3k_tiara.scaffolds.stats.tsv"

  # S500 bin
  echo "[`date '+%F %T'`] Build S500 bin"
  "${SEQKIT_BIN}" seq -m "${BIN_S500_MIN}" -M "${BIN_S500_MAX}" "${SRC_CONTIGS}" > "${SAMPLE}.scaffolds.S500.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.scaffolds.S500.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.S500.scaffolds.stats.tsv"

  tiara -i "${SAMPLE}.scaffolds.S500.fasta" -o "${SAMPLE}.out500.txt" -t "${TIARA_THREADS}" -m "${BIN_S500_MIN}" --tf "${TIARA_TF}"

  safe_cat "${SAMPLE}.tiara_S500.euk.fasta" \
    "eukarya_${SAMPLE}.scaffolds.S500.fasta" \
    "mitochondrion_${SAMPLE}.scaffolds.S500.fasta" \
    "plastid_${SAMPLE}.scaffolds.S500.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S500.euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.S500_euk.stats.tsv"

  safe_cat "${SAMPLE}.tiara_S500.non-euk.fasta" \
    "archaea_${SAMPLE}.scaffolds.S500.fasta" \
    "bacteria_${SAMPLE}.scaffolds.S500.fasta" \
    "prokarya_${SAMPLE}.scaffolds.S500.fasta" \
    "unknown_${SAMPLE}.scaffolds.S500.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S500.non-euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.S500_non-euk.stats.tsv"

  rm -f "${SAMPLE}.scaffolds.S500.fasta" \
        "eukarya_${SAMPLE}.scaffolds.S500.fasta" \
        "mitochondrion_${SAMPLE}.scaffolds.S500.fasta" \
        "plastid_${SAMPLE}.scaffolds.S500.fasta" \
        "archaea_${SAMPLE}.scaffolds.S500.fasta" \
        "bacteria_${SAMPLE}.scaffolds.S500.fasta" \
        "prokarya_${SAMPLE}.scaffolds.S500.fasta" \
        "unknown_${SAMPLE}.scaffolds.S500.fasta"

  # S1000 bin
  echo "[`date '+%F %T'`] Build S1000 bin"
  "${SEQKIT_BIN}" seq -m "${BIN_S1000_MIN}" -M "${BIN_S1000_MAX}" "${SRC_CONTIGS}" > "${SAMPLE}.scaffolds.S1000.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.scaffolds.S1000.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.S1000.scaffolds.stats.tsv"

  tiara -i "${SAMPLE}.scaffolds.S1000.fasta" -o "${SAMPLE}.out1000.txt" -t "${TIARA_THREADS}" -m "${BIN_S1000_MIN}" --tf "${TIARA_TF}"

  safe_cat "${SAMPLE}.tiara_S1000.euk.fasta" \
    "eukarya_${SAMPLE}.scaffolds.S1000.fasta" \
    "mitochondrion_${SAMPLE}.scaffolds.S1000.fasta" \
    "plastid_${SAMPLE}.scaffolds.S1000.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S1000.euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.S1000_euk.stats.tsv"

  safe_cat "${SAMPLE}.tiara_S1000.non-euk.fasta" \
    "archaea_${SAMPLE}.scaffolds.S1000.fasta" \
    "bacteria_${SAMPLE}.scaffolds.S1000.fasta" \
    "prokarya_${SAMPLE}.scaffolds.S1000.fasta" \
    "unknown_${SAMPLE}.scaffolds.S1000.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_S1000.non-euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.S1000_non-euk.stats.tsv"

  rm -f "${SAMPLE}.scaffolds.S1000.fasta" \
        "eukarya_${SAMPLE}.scaffolds.S1000.fasta" \
        "mitochondrion_${SAMPLE}.scaffolds.S1000.fasta" \
        "plastid_${SAMPLE}.scaffolds.S1000.fasta" \
        "archaea_${SAMPLE}.scaffolds.S1000.fasta" \
        "bacteria_${SAMPLE}.scaffolds.S1000.fasta" \
        "prokarya_${SAMPLE}.scaffolds.S1000.fasta" \
        "unknown_${SAMPLE}.scaffolds.S1000.fasta"

  # Merge outputs
  echo "[`date '+%F %T'`] Merge euk/non-euk outputs"
  safe_cat "${SAMPLE}.tiara_merged.euk.fasta" \
    "${SAMPLE}.tiara_S500.euk.fasta" \
    "${SAMPLE}.tiara_S1000.euk.fasta" \
    "${SAMPLE}.tiara_3k.euk.fasta"

  safe_cat "${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta" \
    "${SAMPLE}.tiara_S500.non-euk.fasta" \
    "${SAMPLE}.tiara_S1000.non-euk.fasta"

  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_merged.euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.tiara_merged.euk.stats.tsv"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.tiara_merged_small_contigs.non-euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.tiara_merged_small_contigs.non-euk.stats.tsv"

  rm -f "${SAMPLE}.tiara_S500.euk.fasta" "${SAMPLE}.tiara_S1000.euk.fasta" "${SAMPLE}.tiara_3k.euk.fasta" \
        "${SAMPLE}.tiara_S500.non-euk.fasta" "${SAMPLE}.tiara_S1000.non-euk.fasta"

  ########################
  # KAIJU + EUKREP
  ########################
  echo "[`date '+%F %T'`] Kaiju + EukRep"

  # 1) Kaiju greedy on small non-euk contigs
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

  # Merge the kaiju-rescued small euk contigs with the Tiara-merged euk contigs
  safe_cat "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" \
    "${SAMPLE}.tiara_merged_small_contigs_kaiju_euk.fasta" \
    "${SAMPLE}.tiara_merged.euk.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.01_kaiju_merged_euk.stats.tsv"

  # 2) Kaiju greedy on merged euk; remove viruses/prok
  kaiju -z "${KAIJU_THREADS}" -t "${KAIJU_NODES}" -f "${KAIJU_FMI}" \
    -i "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" \
    -e "${KAIJU_GREEDY_E}" -s "${KAIJU_GREEDY_S}" \
    -o "${SAMPLE}.tiara_kaiju_merged.euk.out"

  kaiju2krona -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
    -i "${SAMPLE}.tiara_kaiju_merged.euk.out" \
    -o "${SAMPLE}.kaiju_new_db_merged-euk.krona"
  ktImportText -o "${SAMPLE}.01_kaiju_greedy_merged-euk.html" "${SAMPLE}.kaiju_new_db_merged-euk.krona"

  kaiju-addTaxonNames -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
    -i "${SAMPLE}.tiara_kaiju_merged.euk.out" -u -p \
    -o "${SAMPLE}_merged-euk.names"

  kaiju2table -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" -r phylum -p \
    -o "${SAMPLE}.01_kaiju_greedy_summary.tsv" \
    "${SAMPLE}.tiara_kaiju_merged.euk.out"

  mkdir -p "${SAMPLE_DIR}/summary"
  mv -f "${SAMPLE}.01_kaiju_greedy_summary.tsv" "${SAMPLE_DIR}/summary/"
  mv -f "${SAMPLE}.01_kaiju_greedy_merged-euk.html" "${SAMPLE_DIR}/summary/"

  grep "Viruses"  "${SAMPLE}_merged-euk.names" > "${SAMPLE}.virus_contigs_greedy" || true
  grep "Bacteria" "${SAMPLE}_merged-euk.names" > "${SAMPLE}.prok1_contigs_greedy" || true
  grep "Archaea"  "${SAMPLE}_merged-euk.names" > "${SAMPLE}.prok2_contigs_greedy" || true
  cat "${SAMPLE}.prok1_contigs_greedy" "${SAMPLE}.prok2_contigs_greedy" > "${SAMPLE}.prok_contigs_greedy" || true
  grep -E '^U\t' "${SAMPLE}.tiara_kaiju_merged.euk.out" | cut -f 2 > "${SAMPLE}.unclassified_contigs_greedy" || true

  cut -f 2 "${SAMPLE}.virus_contigs_greedy" > "${SAMPLE}.virus_contigs_list.txt" || true
  cut -f 2 "${SAMPLE}.prok_contigs_greedy"  > "${SAMPLE}.prok_contigs_list_greedy.txt" || true
  rm -f "${SAMPLE}.virus_contigs_greedy" "${SAMPLE}.prok_contigs_greedy" "${SAMPLE}.prok1_contigs_greedy" "${SAMPLE}.prok2_contigs_greedy"

  "${SEQKIT_BIN}" grep -f "${SAMPLE}.virus_contigs_list.txt" --invert-match \
    "${SAMPLE}.01_tiara_kaiju_merged.euk.fasta" > "${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.stats.tsv"

  "${SEQKIT_BIN}" grep -f "${SAMPLE}.prok_contigs_list_greedy.txt" --invert-match \
    "${SAMPLE}.02_tiara_kaiju_merged.euk-novirus.fasta" > "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.03_euk_novirus_noprok.stats.tsv"

  kaiju -z "${KAIJU_THREADS}" -t "${KAIJU_NODES}" -f "${KAIJU_FMI}" \
    -i "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta" \
    -a mem -m 22 \
    -o "${SAMPLE}.tiara_kaiju_merged.euk-no-virus-noprok.out"

  kaiju2krona -t "${KAIJU_NODES}" -n "${KAIJU_NAMES}" \
    -i "${SAMPLE}.tiara_kaiju_merged.euk-no-virus-noprok.out" \
    -o "${SAMPLE}.kaiju_new_db_mem22.krona"
  ktImportText -o "${SAMPLE}_mem22.html" "${SAMPLE}.kaiju_new_db_mem22.krona"

  # 3) mem22 cleanup
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
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.04_tiara_kaiju_merged.euk-clean.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.04_tiara_kaiju_merged.euk-clean.stats.tsv"

  "${SEQKIT_BIN}" grep -f "${SAMPLE}.unclassified_contigs_greedy" \
    "${SAMPLE}.03_tiara_kaiju_merged.euk-novirus-noprok.fasta" > "${SAMPLE}.05_tiara_kaiju_unclassified.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.05_tiara_kaiju_unclassified.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.05_tiara_kaiju_unclassified.stats.tsv"

  "${SEQKIT_BIN}" grep -f "${SAMPLE}.unclassified_contigs_greedy" --invert-match \
    "${SAMPLE}.04_tiara_kaiju_merged.euk-clean.fasta" > "${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.stats.tsv"
  rm -f "${SAMPLE}.unclassified_contigs_greedy"

  # 4) EukRep on unclassified; merge with clean euk
  EukRep -i "${SAMPLE}.05_tiara_kaiju_unclassified.fasta" -m balanced \
    -o "${SAMPLE}.07_eukrep_balanced1000.euk.fasta" --min 1000

  safe_cat "${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta" \
    "${SAMPLE}.07_eukrep_balanced1000.euk.fasta" \
    "${SAMPLE}.06_tiara_kaiju_merged.euk-clean_noU.fasta"

  "${SEQKIT_BIN}" stats -a "${SAMPLE}.07_eukrep_balanced1000.euk.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.07_eukrep_balanced1000.euk.stats.tsv"
  "${SEQKIT_BIN}" stats -a "${SAMPLE}.08_tiara_kaiju_eukrep.euk-pool.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.08_final_euk_pool.stats.tsv"

  # 5) OPTIONAL step: taxa subset
  if [[ "${DO_TAXON_SUBSET}" -eq 1 ]]; then
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
    "${SEQKIT_BIN}" stats -a "${SAMPLE}.09_euk_pool_only_${SLUG}.fasta" | sed '1d' > "${STATS_DIR}/${SAMPLE}.09_euk_pool_only_${SLUG}.stats.tsv"
  fi
}  

# SLURM array (one sample) or local loop (all samples)
if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  SAMPLE="$(sed -n "${SLURM_ARRAY_TASK_ID}p" "${SAMPLE_LIST}")"
  [[ -n "$SAMPLE" ]] || { echo "Empty SAMPLE for task ${SLURM_ARRAY_TASK_ID}"; exit 1; }
  process_sample "$SAMPLE"
else
  while read -r SAMPLE; do
    [[ -n "$SAMPLE" ]] || continue
    process_sample "$SAMPLE"
  done < "${SAMPLE_LIST}"
fi

