#!/usr/bin/env bash
# =============================================================================
# build-gpt-oss-downloader.sh - Build GPT-OSS Hugging Face downloader image
#
# Builds the custom model download image used by start.sh for GPT-OSS. The
# image extends KServe's storage initializer with hf_transfer and hf_xet support.
#
# Usage:
#   ./scripts/build-gpt-oss-downloader.sh
#   IMAGE=gpt-oss-downloader:hf-transfer ./scripts/build-gpt-oss-downloader.sh
# =============================================================================
set -euo pipefail

IMAGE="${IMAGE:-gpt-oss-downloader:hf-transfer}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RKE2_CTR="${RKE2_CTR:-/var/lib/rancher/rke2/bin/ctr}"
RKE2_CONTAINERD_SOCK="${RKE2_CONTAINERD_SOCK:-/run/k3s/containerd/containerd.sock}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || err "docker is required to build ${IMAGE}"

log "Building ${IMAGE} from Dockerfile.custom-download..."
docker build -t "$IMAGE" -f "${REPO_ROOT}/Dockerfile.custom-download" "$REPO_ROOT"

if [[ -x "$RKE2_CTR" && -S "$RKE2_CONTAINERD_SOCK" ]]; then
  tmp_image="$(mktemp --suffix=.tar)"
  trap 'rm -f "$tmp_image"' EXIT

  log "Exporting ${IMAGE} for containerd import..."
  docker save "$IMAGE" -o "$tmp_image"

  log "Importing ${IMAGE} into RKE2 containerd namespace k8s.io..."
  if [[ "$(id -u)" -eq 0 ]]; then
    "$RKE2_CTR" --address "$RKE2_CONTAINERD_SOCK" -n k8s.io images import "$tmp_image"
  else
    sudo "$RKE2_CTR" --address "$RKE2_CONTAINERD_SOCK" -n k8s.io images import "$tmp_image"
  fi
  log "Imported ${IMAGE} into RKE2 containerd."
else
  log "RKE2 ctr/socket not found; image built in Docker only. Push ${IMAGE} to a registry or import it into your Kubernetes runtime before starting GPT-OSS."
fi

log "Done. Use GPT_OSS_MODEL_DOWNLOAD_IMAGE=${IMAGE} with start.sh if you override the default."
