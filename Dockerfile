# Multi-stage Dockerfile for ComfyUI + JupyterLab on CUDA runtime
# NOTE: Do NOT bake tokens into the image. Use build-args or runtime envs.

ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04
FROM ${BASE_IMAGE} as base

# Consolidated environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    PATH="/opt/venv/bin:$PATH"

# Install system packages and python
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev \
        python3-pip curl ffmpeg ninja-build git aria2 git-lfs wget vim \
        libgl1 libglib2.0-0 build-essential gcc ca-certificates && \
    ln -sf /usr/bin/python3.12 /usr/bin/python && \
    ln -sf /usr/bin/pip3 /usr/bin/pip && \
    python3.12 -m venv /opt/venv && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Use pip cache
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip setuptools wheel

# Install core ML and tooling. Use stable PyTorch cu124 wheel.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Install runtime libraries and CLIs
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install pyyaml gdown triton comfy-cli jupyterlab jupyterlab-lsp \
        jupyter-server jupyter-server-terminals ipykernel jupyterlab_code_formatter \
        huggingface-hub

# Install ComfyUI into /ComfyUI via git and install its requirements
RUN git lfs install && \
    rm -rf /ComfyUI && \
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    /opt/venv/bin/pip install -r /ComfyUI/requirements.txt

# Final stage where custom nodes and workflows are added
FROM base AS final
ENV PATH="/opt/venv/bin:$PATH"

# Install a few extras
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install opencv-python

# Create directories for models, workflows and custom nodes
RUN mkdir -p /ComfyUI/custom_nodes /ComfyUI/workflows /models /downloads
WORKDIR /ComfyUI/custom_nodes

# Copy a default repos list and let fetch_nodes.py ensure they're cloned and updated
COPY src/default_repos.txt /usr/local/bin/default_repos.txt

# Copy workflows if present in build context (place your workflow json files in ./workflows when building)
COPY workflows/ /ComfyUI/workflows/

# Copy helper scripts and node fetcher, then run node fetcher (non-fatal)
COPY src/fetch_nodes.py /usr/local/bin/fetch_nodes.py
COPY src/start_script.sh /start_script.sh
COPY src/download_models.sh /download_models.sh
RUN chmod +x /start_script.sh /download_models.sh /usr/local/bin/fetch_nodes.py /usr/local/bin/default_repos.txt && \
    python3 /usr/local/bin/fetch_nodes.py --workflows /ComfyUI/workflows --target /ComfyUI/custom_nodes --extra-repos-file /usr/local/bin/default_repos.txt --pip /opt/venv/bin/pip || true

# Expose ports
EXPOSE 8188 8888

# Use non-root by default? You can switch to a non-root user if desired.
# For simplicity leave as root (common for GPU containers). Be aware of security implications.

# Entrypoint
CMD ["/start_script.sh"]
