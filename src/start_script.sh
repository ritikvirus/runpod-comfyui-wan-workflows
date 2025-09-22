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

# If workflows were copied into image at build time under /workspace/ComfyUI/workflows, prefer that
if [ -d "/workspace/ComfyUI/workflows" ]; then
  echo "Found built-in /workspace/ComfyUI/workflows; syncing into $WORKSPACE_DIR/workflows"
  cp -a /workspace/ComfyUI/workflows/. "$WORKSPACE_DIR/workflows/" || true
fi

# If a default_repos file exists in the workspace, prefer it so users can override at runtime
if [ -f "/workspace/src/default_repos.txt" ]; then
  cp /workspace/src/default_repos.txt /usr/local/bin/default_repos.txt || true
fi

# Make workspace world-writable so Jupyter/Comfy running as root or non-root can write.
# This follows your request to ensure Jupyter has full permissions inside the workspace.
chmod -R 0777 "$WORKSPACE_DIR" || true

# Ensure current working directory is a valid, persistent path to avoid cwd-related errors in Jupyter/Comfy
cd "$WORKSPACE_DIR" 2>/dev/null || true

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

# Prepare a resolver to fetch the latest download_models.sh dynamically at runtime.
resolve_download_script() {
  # local log helper
  rlog() { echo "$1" >> "$LOGDIR/download.log" 2>&1 || true; }

  # 1) Explicit path wins
  if [ -n "${DOWNLOAD_MODELS_PATH-}" ] && [ -f "$DOWNLOAD_MODELS_PATH" ]; then
    rlog "Using DOWNLOAD_MODELS_PATH=$DOWNLOAD_MODELS_PATH"
    echo "$DOWNLOAD_MODELS_PATH"; return 0
  fi
  # 2) Explicit URL
  if [ -n "${DOWNLOAD_MODELS_URL-}" ]; then
    tmp="/tmp/download_models.sh"
    rlog "Fetching DOWNLOAD_MODELS_URL=$DOWNLOAD_MODELS_URL -> $tmp"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$tmp" "$DOWNLOAD_MODELS_URL" || return 1
    else
      wget -O "$tmp" "$DOWNLOAD_MODELS_URL" || return 1
    fi
    chmod +x "$tmp" || true
    echo "$tmp"; return 0
  fi
  # 3) Workspace copy (repo mounted at runtime)
  if [ -f "$WORKSPACE_DIR/src/download_models.sh" ]; then
    rlog "Found workspace download_models.sh at $WORKSPACE_DIR/src/download_models.sh"
    echo "$WORKSPACE_DIR/src/download_models.sh"; return 0
  fi
  # 4) Try raw from a provided GitHub repo, or fallback to a sane default for this image
  GH_REPO_FALLBACK="ritikvirus/runpod-comfyui-wan-workflows"
  if [ -z "${GITHUB_REPO-}" ]; then
    GITHUB_REPO="$GH_REPO_FALLBACK"
  fi
  if [ -n "${GITHUB_REPO-}" ]; then
    tmp="/tmp/download_models.sh"
    for branch_try in "${GIT_BRANCH:-main}" master; do
      raw_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${branch_try}/src/download_models.sh"
      rlog "Trying raw GitHub fetch: $raw_url -> $tmp"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp" "$raw_url" || true
      else
        wget -O "$tmp" "$raw_url" || true
      fi
      if [ -s "$tmp" ]; then
        chmod +x "$tmp" || true
        rlog "Fetched download_models.sh from $raw_url"
        echo "$tmp"; return 0
      fi
    done
    # As a last resort, clone the repo and copy the script
    repo_url="https://github.com/${GITHUB_REPO}.git"
    tmpdir="$(mktemp -d 2>/dev/null || echo /tmp/dl_repo)"
    branch_clone="${GIT_BRANCH:-main}"
    rlog "Cloning $repo_url (branch=$branch_clone) to fetch script"
    git clone --depth 1 --branch "$branch_clone" "$repo_url" "$tmpdir" >> "$LOGDIR/download.log" 2>&1 || true
    if [ -f "$tmpdir/src/download_models.sh" ]; then
      cp "$tmpdir/src/download_models.sh" "$tmp" 2>/dev/null || true
      chmod +x "$tmp" || true
      rlog "Copied download_models.sh from cloned repo"
      echo "$tmp"; return 0
    fi
  fi
  # 5) As a last resort (not preferred), use image copy if present
  if [ -f "/download_models.sh" ]; then
    rlog "Falling back to image /download_models.sh"
    echo "/download_models.sh"; return 0
  fi
  return 1
}

# Resolve additional requirements file dynamically from multiple sources
resolve_additional_requirements() {
  # local log helper
  alog() { echo "$1" >> "$LOGDIR/comfy.log" 2>&1 || true; }

  # 1) Explicit path wins
  if [ -n "${ADDITIONAL_REQUIREMENTS_PATH-}" ] && [ -f "$ADDITIONAL_REQUIREMENTS_PATH" ]; then
    alog "Using ADDITIONAL_REQUIREMENTS_PATH=$ADDITIONAL_REQUIREMENTS_PATH"
    echo "$ADDITIONAL_REQUIREMENTS_PATH"; return 0
  fi
  # 2) Explicit URL
  if [ -n "${ADDITIONAL_REQUIREMENTS_URL-}" ]; then
    tmp="/tmp/additional_requirements.txt"
    alog "Fetching ADDITIONAL_REQUIREMENTS_URL=$ADDITIONAL_REQUIREMENTS_URL -> $tmp"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$tmp" "$ADDITIONAL_REQUIREMENTS_URL" || return 1
    else
      wget -O "$tmp" "$ADDITIONAL_REQUIREMENTS_URL" || return 1
    fi
    echo "$tmp"; return 0
  fi
  # 3) Workspace copy (repo/files mounted at runtime)
  if [ -f "$WORKSPACE_DIR/additional_requirements.txt" ]; then
    alog "Found workspace additional_requirements.txt at $WORKSPACE_DIR/additional_requirements.txt"
    echo "$WORKSPACE_DIR/additional_requirements.txt"; return 0
  fi
  # 4) Try raw from a provided GitHub repo, or fallback to this image's default repo
  GH_REPO_FALLBACK="ritikvirus/runpod-comfyui-wan-workflows"
  if [ -z "${GITHUB_REPO-}" ]; then
    GITHUB_REPO="$GH_REPO_FALLBACK"
  fi
  if [ -n "${GITHUB_REPO-}" ]; then
    tmp="/tmp/additional_requirements.txt"
    for branch_try in "${GIT_BRANCH:-main}" master; do
      raw_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${branch_try}/additional_requirements.txt"
      alog "Trying raw GitHub fetch: $raw_url -> $tmp"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp" "$raw_url" || true
      else
        wget -O "$tmp" "$raw_url" || true
      fi
      if [ -s "$tmp" ]; then
        alog "Fetched additional_requirements.txt from $raw_url"
        echo "$tmp"; return 0
      fi
    done
    # As a last resort, clone the repo and copy the file
    repo_url="https://github.com/${GITHUB_REPO}.git"
    tmpdir="$(mktemp -d 2>/dev/null || echo /tmp/additional_reqs_repo)"
    branch_clone="${GIT_BRANCH:-main}"
    alog "Cloning $repo_url (branch=$branch_clone) to fetch additional requirements"
    git clone --depth 1 --branch "$branch_clone" "$repo_url" "$tmpdir" >> "$LOGDIR/comfy.log" 2>&1 || true
    if [ -f "$tmpdir/additional_requirements.txt" ]; then
      cp "$tmpdir/additional_requirements.txt" "$tmp" 2>/dev/null || true
      alog "Copied additional_requirements.txt from cloned repo"
      echo "$tmp"; return 0
    fi
  fi
  return 1
}

# Start JupyterLab
echo "Preparing Python environment and starting JupyterLab..."

# Prefer a persistent venv under the workspace if requested (PERSIST_VENV=true). Otherwise fall back to /opt/venv.
VENV_DIR="$WORKSPACE_DIR/.venv"
if [ "${PERSIST_VENV-}" = "true" ]; then
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "Creating persistent venv at $VENV_DIR (this may take a while)..." | tee -a "$LOGDIR/jupyter.log" 1>/dev/null 2>&1 || true
    stdbuf -oL -eL python3 -m venv "$VENV_DIR" 2>&1 | tee -a "$LOGDIR/jupyter.log" || true
    stdbuf -oL -eL "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel 2>&1 | tee -a "$LOGDIR/jupyter.log" || true
    # Install minimal runtime tools in the persistent venv so jupyter/comfy cli are available
    "$VENV_DIR/bin/pip" install comfy-cli jupyterlab huggingface-hub gdown || true
  fi
  # Ensure ComfyUI python requirements are installed into the persistent venv
  if [ -f "/ComfyUI/requirements.txt" ]; then
    echo "Installing ComfyUI requirements into persistent venv" | tee -a "$LOGDIR/jupyter.log" 1>/dev/null 2>&1 || true
    stdbuf -oL -eL "$VENV_DIR/bin/pip" install -r /ComfyUI/requirements.txt 2>&1 | tee -a "$LOGDIR/jupyter.log" || true
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

# Ensure Pillow is available in the active Python environment (ComfyUI requires PIL)
"${PYTHON}" - <<'PY' 2>/dev/null || true
try:
    import PIL  # noqa: F401
    print('Pillow already present')
except Exception:
    raise SystemExit(1)
PY
if [ "$?" -ne 0 ]; then
  echo "Installing Pillow into active venv" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
  if [ -n "${PIP-}" ]; then
    stdbuf -oL -eL "${PIP}" install --no-input --upgrade pillow 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  else
    stdbuf -oL -eL pip install --no-input --upgrade pillow 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  fi
fi

# Force JupyterLab to open in /ComfyUI (requested) regardless of workspace path
JUPYTER_DIR="/ComfyUI"
mkdir -p "$JUPYTER_DIR" || true
echo "Jupyter will use directory: $JUPYTER_DIR" >> "$LOGDIR/jupyter.log" 2>&1 || true
echo "Starting JupyterLab on 0.0.0.0:8888 (notebook-dir=$JUPYTER_DIR)" | tee -a "$LOGDIR/jupyter.log" 1>/dev/null 2>&1 || true
# Disable token for convenience inside controlled environments like Runpod; remove --ServerApp.token='' if you want a token
stdbuf -oL -eL "${PYTHON}" -m jupyter lab \
  --ip=0.0.0.0 --port=8888 --no-browser \
  --ServerApp.token='' --LabApp.allow_origin='*' --ServerApp.allow_remote_access=True \
  --NotebookApp.notebook_dir="$JUPYTER_DIR" --allow-root 2>&1 | tee -a "$LOGDIR/jupyter.log" &
JUPYTER_PID=$!

# Start ComfyUI - try comfy CLI first, fall back to main.py
STARTED=0
# If ComfyUI is installed but CPU-only environment, patch model_management to avoid calling CUDA when it's not available.
COMFY_WS_DIR="$WORKSPACE_DIR/ComfyUI"
# Keep ComfyUI installed at /ComfyUI (no workspace relocation), per requirements

# Ensure /ComfyUI exists and contains a minimal pyproject so comfy_cli imports don't crash
if [ ! -d "/ComfyUI" ]; then
  mkdir -p /ComfyUI || true
fi
if [ ! -f "/ComfyUI/pyproject.toml" ]; then
  cat > /ComfyUI/pyproject.toml <<'PYP'
[tool.comfy]
name = "comfy"
PYP
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

# If ComfyUI main.py is missing, attempt to install via comfy CLI into /ComfyUI
if [ ! -f "/ComfyUI/main.py" ]; then
  echo "ComfyUI main.py not present; attempting to obtain ComfyUI via git clone or comfy CLI" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true

  # Allow overriding which ComfyUI repo to clone at runtime. Default to the main ComfyUI repo.
  COMFY_GIT=${COMFY_GIT:-https://github.com/comfyanonymous/ComfyUI.git}
  if command -v git >/dev/null 2>&1; then
    echo "Cloning ComfyUI from $COMFY_GIT into /ComfyUI" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
    rm -rf /ComfyUI || true
    stdbuf -oL -eL git clone --depth 1 "$COMFY_GIT" /ComfyUI 2>&1 | tee -a "$LOGDIR/comfy.log" || echo "git clone of ComfyUI failed" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
    # Install ComfyUI python requirements if present
    if [ -f "/ComfyUI/requirements.txt" ]; then
      echo "Installing ComfyUI requirements from /ComfyUI/requirements.txt" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
      if [ -n "${PIP-}" ]; then
        stdbuf -oL -eL "$PIP" install -r /ComfyUI/requirements.txt 2>&1 | tee -a "$LOGDIR/comfy.log" || echo "pip install requirements failed" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
      else
        stdbuf -oL -eL pip install -r /ComfyUI/requirements.txt 2>&1 | tee -a "$LOGDIR/comfy.log" || echo "pip install requirements failed" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
      fi
    fi
  else
    echo "git not available; will try comfy CLI install instead" >> "$LOGDIR/comfy.log" 2>&1 || true
  fi

  # After attempting git clone, if comfy CLI exists, run install --upgrade to ensure components are present
  if command -v comfy >/dev/null 2>&1 || [ -x "${VENV_BIN-}/comfy" ]; then
    if [ -x "${VENV_BIN-}/comfy" ]; then
      (cd /ComfyUI && "${VENV_BIN}/comfy" --workspace /ComfyUI install --upgrade) >> "$LOGDIR/comfy.log" 2>&1 || true
    else
      (cd /ComfyUI && comfy --workspace /ComfyUI install --upgrade) >> "$LOGDIR/comfy.log" 2>&1 || true
    fi
  fi

  # If we have a workspace repo with fetch_nodes.py, attempt to install custom nodes listed there
  if [ -f "$WORKSPACE_DIR/src/fetch_nodes.py" ]; then
    echo "Running workspace fetch_nodes.py to install custom nodes" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
    # Use workspace pip if available (PIP variable) so installs go into the persistent venv
    FETCH_PY="$WORKSPACE_DIR/src/fetch_nodes.py"
    if [ -n "${PIP-}" ]; then
      stdbuf -oL -eL python "$FETCH_PY" --workflows "$WORKSPACE_DIR/workflows" --extra-repos-file "$WORKSPACE_DIR/src/default_repos.txt" --pip "$PIP" 2>&1 | tee -a "$LOGDIR/comfy.log" || echo "fetch_nodes.py failed" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
    else
      stdbuf -oL -eL python "$FETCH_PY" --workflows "$WORKSPACE_DIR/workflows" --extra-repos-file "$WORKSPACE_DIR/src/default_repos.txt" 2>&1 | tee -a "$LOGDIR/comfy.log" || echo "fetch_nodes.py failed" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
    fi
  else
    echo "No workspace fetch_nodes.py found at $WORKSPACE_DIR/src/fetch_nodes.py; skipping custom node install" >> "$LOGDIR/comfy.log" 2>&1 || true
  fi
fi

# If ComfyUI is already present, ensure it is fully updated (git fetch/pull and submodules), then re-install requirements if changed.
if [ -d "/ComfyUI/.git" ]; then
  echo "Updating existing /ComfyUI from git" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
  stdbuf -oL -eL git -C /ComfyUI fetch --all --tags --prune 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  stdbuf -oL -eL git -C /ComfyUI pull --rebase --autostash 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  stdbuf -oL -eL git -C /ComfyUI submodule sync --recursive 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  stdbuf -oL -eL git -C /ComfyUI submodule update --init --recursive 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  if [ -f "/ComfyUI/requirements.txt" ]; then
    echo "Re-installing ComfyUI requirements (if updated)" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
    if [ -n "${PIP-}" ]; then
      stdbuf -oL -eL "$PIP" install -r /ComfyUI/requirements.txt 2>&1 | tee -a "$LOGDIR/comfy.log" || true
    else
      stdbuf -oL -eL pip install -r /ComfyUI/requirements.txt 2>&1 | tee -a "$LOGDIR/comfy.log" || true
    fi
  fi
fi

# Ensure workflows are present under /ComfyUI/workflows, preferring any workspace-provided ones
mkdir -p /ComfyUI/workflows || true
if [ -d "$WORKSPACE_DIR/workflows" ]; then
  echo "Syncing workspace workflows into /ComfyUI/workflows" >> "$LOGDIR/comfy.log" 2>&1 || true
  cp -a "$WORKSPACE_DIR/workflows/." /ComfyUI/workflows/ 2>/dev/null || true
fi

# Always attempt to sync/install custom nodes using default repos and workflows at /ComfyUI, using the selected pip (persistent venv if enabled)
if [ -n "${PIP-}" ]; then
  echo "Syncing custom nodes with selected pip ($PIP)" >> "$LOGDIR/comfy.log" 2>&1 || true
  python3 /usr/local/bin/fetch_nodes.py --workflows "/ComfyUI/workflows" --target /ComfyUI/custom_nodes --extra-repos-file /usr/local/bin/default_repos.txt --pip "$PIP" >> "$LOGDIR/comfy.log" 2>&1 || true
else
  echo "Syncing custom nodes with system python/pip" >> "$LOGDIR/comfy.log" 2>&1 || true
  python3 /usr/local/bin/fetch_nodes.py --workflows "/ComfyUI/workflows" --target /ComfyUI/custom_nodes --extra-repos-file /usr/local/bin/default_repos.txt >> "$LOGDIR/comfy.log" 2>&1 || true
fi

# After ComfyUI is fully prepared, resolve and run the model downloader to target /ComfyUI
MODELDOWN_SCRIPT="$(resolve_download_script || true)"
if [ -z "$MODELDOWN_SCRIPT" ]; then
  echo "No download_models.sh available; skipping model downloads" >> "$LOGDIR/download.log" 2>&1 || true
else
  export OUTDIR="/ComfyUI"
  export COMFY_ROOT="/ComfyUI"
  chmod +x "$MODELDOWN_SCRIPT" 2>/dev/null || true
  if [ "${MANDATORY_ON_START-}" = "true" ] || [ -n "${RUNPOD_POD_ID-}" ]; then
    echo "Running mandatory model downloads into /ComfyUI (synchronous)" | tee -a "$LOGDIR/download.log" 1>/dev/null 2>&1 || true
    stdbuf -oL -eL "$MODELDOWN_SCRIPT" 2>&1 | tee -a "$LOGDIR/download.log" || echo "Downloads finished with errors" | tee -a "$LOGDIR/download.log" 1>/dev/null 2>&1 || true
  elif [ -n "${MODELS-}" ] || [ -n "${MODELS_FILE-}" ]; then
    echo "Starting optional model downloads into /ComfyUI (background)" | tee -a "$LOGDIR/download.log" 1>/dev/null 2>&1 || true
    stdbuf -oL -eL "$MODELDOWN_SCRIPT" 2>&1 | tee -a "$LOGDIR/download.log" &
  else
    echo "No MODELS or MODELS_FILE provided; skipping optional downloads" >> "$LOGDIR/download.log" 2>&1 || true
  fi
fi
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"
 
# Install optional additional Python requirements from a resolved source
ADD_REQ_FILE="$(resolve_additional_requirements || true)"
if [ -n "$ADD_REQ_FILE" ] && [ -f "$ADD_REQ_FILE" ]; then
  echo "Installing additional requirements from $ADD_REQ_FILE" | tee -a "$LOGDIR/comfy.log" 1>/dev/null 2>&1 || true
  if [ -n "${PIP-}" ]; then
    stdbuf -oL -eL "$PIP" install -r "$ADD_REQ_FILE" 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  else
    stdbuf -oL -eL pip install -r "$ADD_REQ_FILE" 2>&1 | tee -a "$LOGDIR/comfy.log" || true
  fi
else
  echo "No additional_requirements.txt found to install" >> "$LOGDIR/comfy.log" 2>&1 || true
fi
# Always start ComfyUI via python main.py to avoid interactive CLI prompts
if [ -f "/ComfyUI/main.py" ]; then
  echo "Starting ComfyUI via python main.py (listen=${COMFY_HOST}:${COMFY_PORT})" >> "$LOGDIR/comfy.log"
  cd /ComfyUI || true
  stdbuf -oL -eL "${PYTHON}" main.py --listen "$COMFY_HOST" --port "$COMFY_PORT" 2>&1 | tee -a "$LOGDIR/comfy.log" &
  COMFY_PID=$!
  STARTED=1
else
  echo "ComfyUI not found at /ComfyUI; container may be misbuilt" > "$LOGDIR/comfy.log"
fi

# Keep container alive by waiting on Jupyter and Comfy processes while streaming their logs via tee
sleep 1
echo "Startup complete. PIDs: Jupyter=$JUPYTER_PID Comfy=${COMFY_PID-unknown}. Streaming logs..."
wait $JUPYTER_PID ${COMFY_PID:-} || true
