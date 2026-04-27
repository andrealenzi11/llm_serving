#!/usr/bin/env bash
# ============================================================
# download_model.sh
# Pre-download HuggingFace model weights into the hf-cache
# Docker named volume before starting the stack.
#
# The download is idempotent: re-running verifies existing
# shards by SHA-256 and only fetches missing or corrupt data.
#
# Usage:        ./download_model.sh
# Prerequisites: Docker daemon running, .env populated
# ============================================================

set -euo pipefail

# ===== Constants ===== #
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"
readonly DOWNLOADER_CONTAINER="hf-downloader"
# Parallel shard downloads; increase on high-bandwidth connections
readonly HF_MAX_WORKERS=4

# ===== Cleanup trap ===== #
# Forcibly remove the ephemeral downloader container on any exit
# (normal, error, or SIGINT/SIGTERM) so a stale named container
# cannot block a subsequent run of this script.
cleanup() {
  docker rm -f "${DOWNLOADER_CONTAINER}" &>/dev/null || true
}
trap cleanup EXIT

# ===== Preflight: Docker availability ===== #
# Check both that the docker binary exists and that the daemon
# is reachable before attempting any docker commands.
if ! command -v docker &>/dev/null; then
  printf 'ERROR: docker command not found. Install Docker and try again.\n' >&2
  exit 1
fi
if ! docker info &>/dev/null; then
  printf 'ERROR: Docker daemon is not running or the current user lacks\n' >&2
  printf '       permission to connect (try: sudo usermod -aG docker $USER).\n' >&2
  exit 1
fi

# ===== Load .env ===== #
if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'ERROR: .env not found at %s\n' "${ENV_FILE}" >&2
  printf '       Copy .env.example to .env and fill in HF_TOKEN and HF_MODEL_ID.\n' >&2
  exit 1
fi

# Warn if .env is world-readable; it contains API tokens and secrets.
# The check ANDs the permission bits with octal 004 (others-read).
if (( (8#$(stat -c '%a' "${ENV_FILE}")) & 8#004 )); then
  printf 'WARNING: %s is readable by all users. Run: chmod 600 %s\n' \
    "${ENV_FILE}" "${ENV_FILE}" >&2
fi

# `set -a` auto-exports every variable assigned after it; `set +a`
# stops that. Together they export all KEY=VALUE pairs from .env
# into the environment without requiring explicit `export` lines.
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# ===== Validate required variables ===== #
: "${HF_TOKEN:?HF_TOKEN must be set in .env}"
: "${HF_MODEL_ID:?HF_MODEL_ID must be set in .env}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-llm_serving}"

# ===== Resolve vLLM image from docker-compose.yaml ===== #
# awk anchors to the `vllm:` service block first, then extracts
# the first `image:` value found within it. This is more robust
# than grep -m1 'image: vllm/', which would match any line in the
# file containing that string (e.g. a comment in another service).
VLLM_IMAGE="$(awk '/^  vllm:/{found=1} found && /image:/{print $2; exit}' \
              "${COMPOSE_FILE}" | tr -d '"' | tr -d "'")"
readonly VLLM_IMAGE

if [[ -z "${VLLM_IMAGE}" ]]; then
  printf 'ERROR: Could not parse vLLM image from %s\n' "${COMPOSE_FILE}" >&2
  exit 1
fi

# ===== Derive Docker volume name ===== #
# docker compose prefixes the project name to every named volume,
# producing "<project>_<volume-name>" (e.g. "llm_serving_hf-cache").
readonly VOLUME_NAME="${COMPOSE_PROJECT_NAME}_hf-cache"

# ===== Ensure the named volume exists ===== #
# docker compose up would create the volume automatically, but
# creating it here lets the standalone `docker run` below mount it
# before the compose stack has ever been started.
if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  printf 'Creating Docker volume: %s\n' "${VOLUME_NAME}"
  docker volume create "${VOLUME_NAME}"
fi

# ===== Print run summary ===== #
printf '============================================================\n'
printf '  Model       : %s\n' "${HF_MODEL_ID}"
printf '  Volume      : %s  →  /root/.cache/huggingface\n' "${VOLUME_NAME}"
printf '  Image       : %s\n' "${VLLM_IMAGE}"
printf '  Max workers : %s\n' "${HF_MAX_WORKERS}"
printf '============================================================\n\n'

# ===== Pull vLLM image ===== #
# Pulling explicitly gives cleaner layered-download progress output;
# leaving it to `docker run` would print nothing until the pull finishes.
printf 'Pulling image (skipped if already cached locally)...\n'
docker pull "${VLLM_IMAGE}"

# ===== Stop any leftover downloader container ===== #
# If a previous run was killed without triggering the EXIT trap
# (e.g. terminal closed, SIGKILL) the container keeps running and
# holds the HF hub lock. Kill it now so it cannot re-acquire the
# lock after we remove the stale lock files below.
docker rm -f "${DOWNLOADER_CONTAINER}" &>/dev/null || true

# ===== Clear stale lock files ===== #
# An interrupted download leaves lock files behind; the next run
# will block indefinitely waiting to acquire them. Safe to remove
# because no other process holds them at this point (container
# above was just force-removed).
HF_LOCK_DIR="models--$(printf '%s' "${HF_MODEL_ID}" | tr '/' '--')"
docker run --rm \
  --user root \
  -v "${VOLUME_NAME}:/root/.cache/huggingface" \
  alpine \
  rm -rf "/root/.cache/huggingface/hub/.locks/${HF_LOCK_DIR}"

# ===== Download model weights into the named volume ===== #
# hf download saves files to the Hub cache layout at
# ~/.cache/huggingface/hub/ (blobs + symlinked snapshots), which is
# exactly the path vLLM scans at startup — no extra flags needed.
# --max-workers parallelises the individual shard downloads.
# --tty allocates a pseudo-TTY inside the container so that tqdm
#   (the progress-bar library used by hf) detects a
#   real terminal and renders per-shard progress bars with speed,
#   percentage and ETA. Without it tqdm falls back to silent mode.
printf '\nStarting download (large models can take a significant amount of time)...\n'
docker run --rm \
  --name "${DOWNLOADER_CONTAINER}" \
  --network bridge \
  --tty \
  --entrypoint hf \
  -e HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}" \
  -v "${VOLUME_NAME}:/root/.cache/huggingface" \
  "${VLLM_IMAGE}" \
  download "${HF_MODEL_ID}" \
    --max-workers "${HF_MAX_WORKERS}"

# ===== Done ===== #
printf '\n============================================================\n'
printf '  Download complete.\n'
printf '  Weights are in Docker volume : %s\n' "${VOLUME_NAME}"
printf '  Start the stack with         : docker compose up -d\n'
printf '============================================================\n'

# === Verify the cache folder contents (optional) === #
# Uncomment the lines below to list the downloaded files and their sizes.
printf '\nDownloaded files:\n'
docker run --rm \
  -v "${VOLUME_NAME}:/root/.cache/huggingface" \
  alpine \
  sh -c 'ls -lh /root/.cache/huggingface/'
