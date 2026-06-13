#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-eai}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_device() {
  if [[ -n "${DEVICE:-}" ]]; then
    echo "${DEVICE}"
  elif have_cmd nvidia-smi && nvidia-smi --list-gpus 2>/dev/null | grep -q "GPU"; then
    echo "cuda"
  elif have_cmd rocm-smi && rocm-smi --showuniqueid 2>/dev/null | grep -q "ID:"; then
    echo "rocm"
  else
    echo "cpu"
  fi
}

DEVICE="$(detect_device)"
export PROJECT DEVICE

# Ensure no Python environment is active before creating this repo's venv.
if [[ -n "${VIRTUAL_ENV:-}" ]] && declare -F deactivate >/dev/null 2>&1; then
  deactivate
fi
if have_cmd conda; then
  while [[ -n "${CONDA_DEFAULT_ENV:-}" ]]; do
    conda deactivate
  done
fi

echo "========================================"
echo "Setup: ${PROJECT}-${DEVICE}"
echo "========================================"
echo "Setup Python Virtual Environment"

VENV="${VENV:-.${PROJECT}-${DEVICE}-venv}"
python3 -m venv "${VENV}"
# shellcheck disable=SC1091
source "${VENV}/bin/activate"

export WORKSPACE="${WORKSPACE:-"${HOME}/workspace"}"
export WORKDIR="${SCRIPT_DIR}"

if ! have_cmd jq; then
  if have_cmd apt-get; then
    echo "========================================"
    echo "Installing jq"
    sudo apt-get update
    sudo apt-get install -y jq
  else
    echo "WARN: jq is not installed and apt-get is unavailable; install jq manually if scripts require it." >&2
  fi
fi

echo "========================================"
echo "Install Python dependencies"

python -m pip install --upgrade pip wheel setuptools
if [[ -f requirements.txt ]]; then
  python -m pip install -U -r requirements.txt
else
  echo "No requirements.txt found; installed only base packaging tools."
fi
python -m pip list

echo "========================================"
if have_cmd amd-smi; then
  amd-smi
elif have_cmd rocm-smi; then
  rocm-smi
elif have_cmd nvidia-smi; then
  nvidia-smi
else
  echo "No GPU management CLI found; setup completed for DEVICE=${DEVICE}."
fi
