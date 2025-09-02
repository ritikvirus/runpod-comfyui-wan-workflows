#!/usr/bin/env bash
set -euo pipefail

# download_models.sh
# Usage:
# - Supply MODELS as a newline-, space-, comma- or semicolon-separated list of model ids or URLs
#   e.g. MODELS=$'owner1/modelA\nowner2/modelB' ./download_models.sh
# - Or point MODELS_FILE to a file with one model id/URL per line
# Examples:
# MODELS="CompVis/stable-diffusion-v1-4,owner2/modelB,https://.../file.safetensors" ./download_models.sh
# MODELS_FILE=/workspace/model_list.txt ./download_models.sh

OUTDIR=${OUTDIR:-/models}
mkdir -p "$OUTDIR"

# Load models from file if provided
if [ -n "${MODELS_FILE-}" ] && [ -f "${MODELS_FILE}" ]; then
  echo "Reading models from file: $MODELS_FILE"
  # read file into MODELS with newline separators
  MODELS=$(sed -e 's/\r$//' "$MODELS_FILE")
fi

if [ -z "${MODELS-}" ]; then
  echo "No MODELS variable set and no MODELS_FILE provided. Nothing to download." >&2
  exit 0
fi

echo "Models will be downloaded to: $OUTDIR"

# login to huggingface if token provided (non-fatal diagnostic)
if [ -n "${HUGGINGFACE_TOKEN-}" ]; then
  echo "HUGGINGFACE_TOKEN provided (not printed for security)."
fi

# Normalize separators: commas and semicolons -> newlines, keep existing newlines/spaces
# Replace commas/semicolons with newlines, then split on newlines and spaces
normalized=$(printf '%s' "$MODELS" | tr ',' '\n' | tr ';' '\n')

# iterate each non-empty trimmed entry
echo "$normalized" | while IFS= read -r line || [ -n "$line" ]; do
  m_trim=$(echo "$line" | tr -d '\r' | sed 's/^\s*//;s/\s*$//')
  if [ -z "$m_trim" ]; then
    continue
  fi
  echo "Processing: $m_trim"

  # If it looks like a huggingface id (owner/model), try snapshot_download
  if echo "$m_trim" | grep -qE '^[^/]+/[^/]+$'; then
    echo "Downloading HF model: $m_trim"
    python - <<PY
from huggingface_hub import snapshot_download
import os,sys
m='''$m_trim'''
out=os.environ.get('OUTDIR','/models')
try:
    path=snapshot_download(repo_id=m, cache_dir=out, repo_type='model', use_auth_token=os.environ.get('HUGGINGFACE_TOKEN'))
    print('Downloaded to', path)
except Exception as e:
    print('Failed to download', m, e)
    sys.exit(1)
PY
  else
    # treat as URL - download into OUTDIR
    echo "Downloading URL: $m_trim"
    # Prefer aria2c if present, otherwise curl
    if command -v aria2c >/dev/null 2>&1; then
      aria2c -x 16 -s 16 -d "$OUTDIR" -o "$(basename "$m_trim")" "$m_trim" || echo "aria2 failed for $m_trim"
    else
      echo "aria2c not found, falling back to curl"
      curl -L --retry 3 -o "$OUTDIR/$(basename "$m_trim")" "$m_trim" || echo "curl failed for $m_trim"
    fi
  fi
done

echo "Downloads complete"
