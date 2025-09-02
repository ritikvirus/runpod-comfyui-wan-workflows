#!/usr/bin/env bash
set -euo pipefail

# download_models.sh
# Usage: set MODELS env var to a newline- or space-separated list of model identifiers.
# Examples:
# MODELS="CompVis/stable-diffusion-v1-4" ./download_models.sh

OUTDIR=/models
mkdir -p "$OUTDIR"

if [ -z "${MODELS-}" ]; then
  echo "No MODELS variable set. Nothing to download." >&2
  exit 0
fi

# login to huggingface if token provided
if [ -n "${HUGGINGFACE_TOKEN-}" ]; then
  echo "Logging in to huggingface hub"
  python - <<PY
from huggingface_hub import HfApi, snapshot_download
import os, sys
TOKEN=os.environ.get('HUGGINGFACE_TOKEN')
if TOKEN:
    print('Token present')
else:
    print('No token')
PY
fi

# Prefer huggingface-hub's snapshot_download for HF ids, fall back to aria2 for urls
IFS=$'\n'
for m in $MODELS; do
  m_trim=$(echo "$m" | tr -d '\r' | sed 's/^\s*//;s/\s*$//')
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
m='$m_trim'
out=os.environ.get('OUTDIR','/models')
try:
    path=snapshot_download(repo_id=m, cache_dir=out, repo_type='model', use_auth_token=os.environ.get('HUGGINGFACE_TOKEN'))
    print('Downloaded to', path)
except Exception as e:
    print('Failed to download', m, e)
    sys.exit(1)
PY
  else
    # treat as URL - use aria2c into /downloads
    echo "Downloading URL: $m_trim"
    aria2c -x 16 -s 16 -d /downloads -o "$(basename "$m_trim")" "$m_trim" || echo "aria2 failed for $m_trim"
  fi
done

echo "Downloads complete"
