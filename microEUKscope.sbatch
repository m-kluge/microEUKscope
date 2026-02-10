#!/bin/bash -l
#SBATCH -J microEUKscope
## Set time/partition/account/array/CPUs/mem etc according to your cluster

set -euo pipefail

# pull settings
source config.env

# Put the env's bin FIRST on PATH (no conda activation needed)
if [[ -z "${ENV_PREFIX:-}" || ! -d "${ENV_PREFIX}/bin" ]]; then
  echo "ERROR: ENV_PREFIX is not set to an existing conda env prefix (…/env/bin)." >&2
  exit 1
fi

export PATH="${ENV_PREFIX}/bin:${PATH}"
# Optional (usually not needed, but safe):
export LD_LIBRARY_PATH="${ENV_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

# run the core pipeline (array index is handled inside)
bash microEUKscope_core.sh
