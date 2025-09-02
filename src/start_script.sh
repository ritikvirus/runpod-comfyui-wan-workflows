#!/usr/bin/env bash
set -euo pipefail

# Start script to launch background prefetch of models, JupyterLab and ComfyUI.
# This script expects optional environment variables:
# - HUGGINGFACE_TOKEN: used by download_models.sh to fetch from HF
# - MODELS: newline or space-separated list of model IDs/URLs to prefetch
# - CIVITAI_TOKEN: (optional) token to access civitai API if you have tooling

# Determine workspace root. Priority: WORKSPACE_DIR env -> WORKSPACE env -> /workspace
WORKSPACE_DIR=${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}
echo "Using workspace: $WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR"

# Logdir (prefer workspace so logs persist if workspace is mounted)
LOGDIR=${WORKSPACE_DIR}/logs
mkdir -p "$LOGDIR"

# Ensure log files exist so tail can open them even if no downloader ran
touch "$LOGDIR/download.log" "$LOGDIR/jupyter.log" "$LOGDIR/comfy.log" || true

# Create standard workspace subfolders (models, downloads, ComfyUI, custom_nodes, workflows)
mkdir -p "$WORKSPACE_DIR/ComfyUI" \
         "$WORKSPACE_DIR/custom_nodes" \
         "$WORKSPACE_DIR/workflows" \
         "$WORKSPACE_DIR/models" \
         "$WORKSPACE_DIR/downloads"

# Make workspace world-writable so Jupyter/Comfy running as root or non-root can write.
# This follows your request to ensure Jupyter has full permissions inside the workspace.
chmod -R 0777 "$WORKSPACE_DIR" || true

# If the workspace appears empty and a repo URL is provided, clone it so the container
# can pick up the latest start/download scripts from your GitHub repository at runtime.
# Provide the repo via GIT_REPO (HTTPS) or GITHUB_REPO (owner/repo) and optional GIT_BRANCH.
if [ -z "$(ls -A "$WORKSPACE_DIR" 2>/dev/null || true)" ]; then
  if [ -n "${GIT_REPO-}" ] || [ -n "${GITHUB_REPO-}" ]; then
    echo "Workspace empty: attempting to clone repository into $WORKSPACE_DIR" >> "$LOGDIR/jupyter.log" 2>&1 || true
    repo_url="${GIT_REPO-}"
    if [ -z "$repo_url" ] && [ -n "${GITHUB_REPO-}" ]; then
      repo_url="https://github.com/${GITHUB_REPO}.git"
    fi
    branch="${GIT_BRANCH:-main}"
    if [ -n "$repo_url" ]; then
      echo "Cloning $repo_url (branch: $branch)" >> "$LOGDIR/jupyter.log" 2>&1 || true
      git clone --depth 1 --branch "$branch" "$repo_url" "$WORKSPACE_DIR" >> "$LOGDIR/jupyter.log" 2>&1 || echo "git clone failed" >> "$LOGDIR/jupyter.log" 2>&1 || true
      # Ensure files are owned and writable
      chmod -R 0777 "$WORKSPACE_DIR" || true
    fi
  fi
fi

# Start model downloader in background if MODELS is provided
if [ -n "${MODELS-}" ]; then
  echo "Starting model downloader..." > "$LOGDIR/download.log"
  # Run downloader with environment; prefer workspace-backed downloads directory
  DOWNLOADS_DIR="$WORKSPACE_DIR/downloads"
  MODELDOWN_CMD="/download_models.sh"
  (cd "$WORKSPACE_DIR" && "$MODELDOWN_CMD") > "$LOGDIR/download.log" 2>&1 &
fi

# Start JupyterLab
echo "Preparing Python environment and starting JupyterLab..."

# Prefer a persistent venv under the workspace if requested (PERSIST_VENV=true). Otherwise fall back to /opt/venv.
VENV_DIR="$WORKSPACE_DIR/.venv"
if [ "${PERSIST_VENV-}" = "true" ]; then
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "Creating persistent venv at $VENV_DIR (this may take a while)..." >> "$LOGDIR/jupyter.log" 2>&1 || true
    python3 -m venv "$VENV_DIR" >> "$LOGDIR/jupyter.log" 2>&1 || true
    "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel >> "$LOGDIR/jupyter.log" 2>&1 || true
    # Install minimal runtime tools in the persistent venv so jupyter/comfy cli are available
    "$VENV_DIR/bin/pip" install comfy-cli jupyterlab huggingface-hub || true
  fi
fi

# If workspace venv exists use it, otherwise fall back to image venv (/opt/venv) if present
if [ -x "$VENV_DIR/bin/python" ]; then
  VENV_BIN="$VENV_DIR/bin"
  export PATH="$VENV_BIN:$PATH"
  PYTHON="$VENV_BIN/python"
  PIP="$VENV_BIN/pip"
else
  PYTHON="$(command -v python || true)"
  PIP="$(command -v pip || true)"
fi

echo "Jupyter will use workspace dir: $WORKSPACE_DIR" >> "$LOGDIR/jupyter.log" 2>&1 || true
echo "Starting JupyterLab on 0.0.0.0:8888 (notebook-dir=$WORKSPACE_DIR)" >> "$LOGDIR/jupyter.log" 2>&1 || true
# Disable token for convenience inside controlled environments like Runpod; remove --ServerApp.token='' if you want a token
"${PYTHON}" -m jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token='' --LabApp.allow_origin='*' --ServerApp.allow_remote_access=True --NotebookApp.notebook_dir="$WORKSPACE_DIR" --allow-root > "$LOGDIR/jupyter.log" 2>&1 &

# Start ComfyUI - try comfy CLI first, fall back to main.py
STARTED=0
# If ComfyUI is installed but CPU-only environment, patch model_management to avoid calling CUDA when it's not available.
COMFY_WS_DIR="$WORKSPACE_DIR/ComfyUI"
# If /ComfyUI exists in image, move or link it into the workspace so ComfyUI state is persisted
if [ -d "/ComfyUI" ] && [ ! -L "/ComfyUI" ]; then
  # If workspace ComfyUI is empty, move existing installation into workspace; otherwise keep workspace version
  if [ -z "$(ls -A "$COMFY_WS_DIR" 2>/dev/null || true)" ]; then
    echo "Moving existing /ComfyUI contents into workspace ($COMFY_WS_DIR)" >> "$LOGDIR/comfy.log" 2>&1 || true
    mkdir -p "$COMFY_WS_DIR"
    # try move, fall back to copy
    mv /ComfyUI/* "$COMFY_WS_DIR/" 2>/dev/null || cp -a /ComfyUI/* "$COMFY_WS_DIR/" 2>/dev/null || true
  fi
  rm -rf /ComfyUI 2>/dev/null || true
  ln -s "$COMFY_WS_DIR" /ComfyUI || true
fi

if [ -f "/ComfyUI/comfy/model_management.py" ]; then
  echo "Checking if CUDA is available before patching model_management" >> "$LOGDIR/comfy.log" 2>&1 || true
  # Only apply the CPU fallback patch when CUDA is not available.
  python - <<'PY' >> "$LOGDIR/comfy.log" 2>&1 || true
import sys
try:
  import torch
  if getattr(torch, 'cuda', None) and torch.cuda.is_available():
    print('CUDA available; skipping CPU fallback patch')
    sys.exit(0)
except Exception as e:
  print('torch.cuda not available or import failed:', e)

import re
path='/ComfyUI/comfy/model_management.py'
try:
  s=open(path,'r',encoding='utf-8').read()
  m=re.search(r"def get_torch_device\([\s\S]*?\n(?=def |$)", s)
  replacement='''def get_torch_device():
  import torch
  try:
    if getattr(torch, 'cuda', None) and torch.cuda.is_available():
      return torch.device(torch.cuda.current_device())
  except Exception:
    pass
  return torch.device('cpu')
'''
  if m:
    s = s[:m.start()] + replacement + s[m.end():]
    open(path,'w',encoding='utf-8').write(s)
    print('patched', path)
  else:
    print('pattern not found in', path)
except Exception as e:
  print('patch failed', e)
PY
fi
if command -v comfy >/dev/null 2>&1 || [ -x "${VENV_BIN-}/comfy" ]; then
  echo "Starting ComfyUI via comfy CLI" >> "$LOGDIR/comfy.log" 2>&1 || true
  # Try comfy CLI from venv if available; start in background and append logs
  if [ -x "${VENV_BIN-}/comfy" ]; then
    "${VENV_BIN}/comfy" --workspace /ComfyUI run >> "$LOGDIR/comfy.log" 2>&1 &
  else
    comfy --workspace /ComfyUI run >> "$LOGDIR/comfy.log" 2>&1 &
  fi
  # Give comfy a moment to initialize and write logs
  sleep 4
  # If comfy didn't start a server, try main.py
  if ! grep -q "Serving" "$LOGDIR/comfy.log" 2>/dev/null; then
    if [ -f "/ComfyUI/main.py" ]; then
      echo "Fallback: starting ComfyUI via python main.py" >> "$LOGDIR/comfy.log"
      cd /ComfyUI || true
      "${PYTHON}" main.py >> "$LOGDIR/comfy.log" 2>&1 &
      STARTED=1
    else
      echo "ComfyUI not found at /ComfyUI; container may be misbuilt" >> "$LOGDIR/comfy.log"
    fi
  else
    STARTED=1
  fi
elif [ -f "/ComfyUI/main.py" ]; then
  echo "Starting ComfyUI via python main.py" >> "$LOGDIR/comfy.log"
  cd /ComfyUI || true
  "${PYTHON}" main.py > "$LOGDIR/comfy.log" 2>&1 &
  STARTED=1
else
  echo "ComfyUI not found at /ComfyUI; container may be misbuilt" > "$LOGDIR/comfy.log"
fi

# Tail logs to keep container alive and to surface logs in docker logs
sleep 1
echo "Tailing logs (jupyter/comfy/download)"
# Use tail -F so new logs are followed
tail -F "$LOGDIR/jupyter.log" "$LOGDIR/comfy.log" "$LOGDIR/download.log" || tail -F "$LOGDIR/jupyter.log" "$LOGDIR/comfy.log" || tail -F "$LOGDIR/jupyter.log"
