#!/usr/bin/env bash
set -euo pipefail

source config.env

PART="${PIPELINE_PARTITION:-main}"
ACCT="${PIPELINE_ACCOUNT:-your-account}"
TIME="${PIPELINE_TIME:-20:00:00}"
CPUS="${PIPELINE_CPUS:-20}"
MEM="${PIPELINE_MEM:-}"
NODES="${PIPELINE_NODES:-}"
NTASKS_PER_NODE="${PIPELINE_NTASKS_PER_NODE:-}"
EXCL="${PIPELINE_EXCLUSIVE:-}"
MAIL_T="${PIPELINE_MAIL_TYPE:-}"
MAIL_U="${PIPELINE_MAIL_USER:-}"

N=$(wc -l < "${SAMPLE_LIST}")

args=(-p "$PART" -A "$ACCT" -t "$TIME" -J microEUKscope --array="1-${N}" --ntasks=1 --cpus-per-task="$CPUS")
[[ -n "$MEM" ]] && args+=(--mem="$MEM")
[[ -n "$NODES" ]] && args+=(--nodes="$NODES")
[[ -n "$NTASKS_PER_NODE" ]] && args+=(--ntasks-per-node="$NTASKS_PER_NODE")
[[ "${EXCL,,}" =~ ^(1|yes|true)$ ]] && args+=(--exclusive)
[[ -n "$MAIL_T" ]] && args+=(--mail-type="$MAIL_T")
[[ -n "$MAIL_U" ]] && args+=(--mail-user="$MAIL_U")

sbatch --chdir "$(pwd)" "${args[@]}" microEUKscope.sbatch
