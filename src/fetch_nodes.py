#!/usr/bin/env python3
"""
fetch_nodes.py

Robust helper to ensure custom nodes referenced by ComfyUI workflows and
by a default repo list are present under the custom_nodes folder.

Features added:
- idempotent: if a repo exists, do a 'git fetch && git pull' and update submodules
- clones with --recurse-submodules when creating new clones
- supports an extra repos file (plain text, one URL per line)
- installs requirements.txt and runs install.py if present
- can be passed a --pip argument to pick which pip to use (build vs runtime venv)

Usage examples:
  python3 fetch_nodes.py --workflows /ComfyUI/workflows --target /ComfyUI/custom_nodes \
      --extra-repos-file /usr/local/bin/default_repos.txt --pip /opt/venv/bin/pip

This script still contains a best-effort mapping for cnr_id -> repo URLs. Add
missing mappings to DEFAULT_MAP or supply repo URLs via --extra-repos-file.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
from pathlib import Path


DEFAULT_MAP = {
    "comfyui-kjnodes": "https://github.com/kijai/ComfyUI-KJNodes.git",
    "rgthree-comfy": "https://github.com/rgthree/rgthree-comfy.git",
    "cg-use-everywhere": "https://github.com/chrisgoringe/cg-use-everywhere.git",
    "was-node-suite-comfyui": "https://github.com/WASasquatch/was-node-suite-comfyui.git",
    "comfyui-florence2": "https://github.com/kijai/ComfyUI-Florence2.git",
    "comfyui-frame-interpolation": "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git",
    "comfyui_essentials": "https://github.com/cubiq/ComfyUI_essentials.git",
    "comfyui-videohelpersuite": "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git",
    "comfyui-crystools": "https://github.com/rgthree/comfyui-crystools.git",
    "comfyui_tinyterranodes": "https://github.com/comfyanonymous/comfyui_tinyterranodes.git",
    "teacache": "https://github.com/welltop-cn/ComfyUI-TeaCache.git",
    # best-effort guesses below; update if you have a preferred repo URL
    "crt-nodes": "https://github.com/ComfyUI-Community/CRT-Nodes.git",
    "comfyui-chibi-nodes": "https://github.com/erred-io/ComfyUI-Chibi-Nodes.git",
    "comfyui-gguf": "https://github.com/erred-io/ComfyUI-GGUF.git",
    "aegisflow_utility_nodes": "https://github.com/aegisflow/aegisflow_utility_nodes.git",
    "comfy-image-saver": "https://github.com/rgthree/comfyui-image-saver.git",
    # ignore builtin/core placeholder
    "comfy-core": None,
}

LOGFILE = "/var/log/fetch_nodes.log"


def log(msg):
    print(msg)
    try:
        with open(LOGFILE, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def run(cmd, cwd=None, check=True, env=None):
    log(f"RUN: {cmd} (cwd={cwd})")
    try:
        subprocess.check_call(shlex.split(cmd), cwd=cwd, env=env)
        return True
    except subprocess.CalledProcessError as e:
        log(f"ERR: command failed: {e}")
        return False


def parse_workflows(workflows_dir):
    cnrs = set()
    p = Path(workflows_dir)
    if not p.exists():
        return []
    for fp in p.glob("*.json"):
        try:
            data = json.loads(fp.read_text())
        except Exception as e:
            log(f"WARN: failed to parse {fp}: {e}")
            continue
        txt = json.dumps(data)
        for m in re.findall(r'"cnr_id"\s*:\s*"([^"]+)"', txt):
            cnrs.add(m)
    return sorted(cnrs)


def pip_install(pip_exec, req_path):
    if not os.path.exists(req_path):
        return True
    if pip_exec and os.path.exists(pip_exec):
        return run(f"{pip_exec} install -r {shlex.quote(req_path)}")
    # fallback to module invocation
    return run(f"python3 -m pip install -r {shlex.quote(req_path)}")


def sync_repo(repo_url, target_dir, pip_exec=None):
    repo_name = os.path.basename(repo_url).replace('.git', '')
    repo_dir = os.path.join(target_dir, repo_name)
    # clone if missing
    if not os.path.exists(repo_dir):
        log(f"CLONING: {repo_url} -> {repo_dir}")
        # try clone with submodules
        if not run(f"git clone --recurse-submodules --depth 1 {shlex.quote(repo_url)} {shlex.quote(repo_dir)}"):
            log(f"ERROR: clone failed for {repo_url}")
            return False
    else:
        log(f"PRESENT: {repo_dir}, attempting fetch & pull")
        # try to fetch remote updates and pull
    run(f"git -C {shlex.quote(repo_dir)} fetch --all --tags --prune")
    run(f"git -C {shlex.quote(repo_dir)} pull --rebase --autostash")
    # update submodules recursively
    run(f"git -C {shlex.quote(repo_dir)} submodule sync --recursive")
    run(f"git -C {shlex.quote(repo_dir)} submodule update --init --recursive")

    # attempt to install requirements and run install.py if present
    req = os.path.join(repo_dir, "requirements.txt")
    if os.path.exists(req):
        if not pip_install(pip_exec, req):
            log(f"WARN: pip install -r {req} failed for {repo_name}")

    install_py = os.path.join(repo_dir, "install.py")
    if os.path.exists(install_py):
        # run using python3 from environment
        if not run(f"python3 {shlex.quote(install_py)}", cwd=repo_dir):
            log(f"WARN: install.py failed for {repo_name}")

    return True


def load_extra_repos(file_path):
    repos = []
    if not file_path:
        return repos
    p = Path(file_path)
    if not p.exists():
        return repos
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        repos.append(line)
    return repos


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflows", required=False)
    parser.add_argument("--target", required=True)
    parser.add_argument("--extra-repos-file", required=False, help="Plain file with one repo URL per line")
    parser.add_argument("--pip", required=False, help="Path to pip executable to use for installs")
    args = parser.parse_args()

    os.makedirs(args.target, exist_ok=True)

    pip_exec = args.pip or os.environ.get('PIP_EXEC') or "/opt/venv/bin/pip"
    if not os.path.exists(pip_exec):
        pip_exec = None

    cnrs = []
    if args.workflows:
        cnrs = parse_workflows(args.workflows)
    log(f"Found cnr_ids in workflows: {cnrs}")

    # handle DEFAULT_MAP entries for cnr_ids
    missing_map = []
    for c in cnrs:
        key = c
        k = key.lower()
        repo = DEFAULT_MAP.get(key) or DEFAULT_MAP.get(k) or None
        if repo is None:
            # try smart guesses
            guess = None
            if "rgthree" in k:
                guess = "https://github.com/rgthree/rgthree-comfy.git"
            elif "crt" in k or "crt-nodes" in k:
                guess = "https://github.com/ComfyUI-Community/CRT-Nodes.git"
            if guess:
                repo = guess
        if repo:
            sync_repo(repo, args.target, pip_exec=pip_exec)
        else:
            log(f"NO REPO MAPPING for cnr_id '{c}' - please add mapping to DEFAULT_MAP or supply via --extra-repos-file")
            missing_map.append(c)

    # process extra repos file if present
    extra = load_extra_repos(args.extra_repos_file)
    if extra:
        log(f"Processing extra repos file: {args.extra_repos_file} ({len(extra)} entries)")
        for r in extra:
            sync_repo(r, args.target, pip_exec=pip_exec)

    if missing_map:
        log("Some cnr_ids had no mapping. Please review and add mappings in fetch_nodes.py or pass repo URLs via --extra-repos-file:")
        for m in missing_map:
            log(f" - {m}")


if __name__ == '__main__':
    main()
