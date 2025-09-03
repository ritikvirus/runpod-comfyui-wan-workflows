Docker image for ComfyUI + JupyterLab (Runpod-ready)

Summary
- Provides a multi-stage Dockerfile that installs ComfyUI, common community custom nodes, and JupyterLab.
- Includes helper scripts to prefetch models into /models and to start both JupyterLab and ComfyUI automatically.

Important notes for macOS M2 (Apple Silicon)
- The base image uses NVIDIA CUDA (x86_64). You cannot build a CUDA image that runs GPU-accelerated workloads on an M2 locally.
- Build and push the image from an x86_64 machine with NVIDIA drivers (for example, a Runpod build node, a Linux GPU host, or CI like GitHub Actions using an x86 runner). Alternatively, use cross-build but you still need an x86_64 runtime to actually run CUDA workloads.

Security - tokens
- Do NOT bake tokens into the image. Use build-args or runtime environment variables.
- Example: pass Hugging Face token at runtime: -e HUGGINGFACE_TOKEN=xxx

How to build (recommended from x86_64 host / CI)
- Place any workflow JSON files under a local `workflows/` directory (these will be copied into `/ComfyUI/workflows` during build)

Example build (on x86_64 host):

  docker build -t myrepo/comfyui-runpod:latest .

Example run (Runpod / other GPU host)

  docker run --gpus all -p 8188:8188 -p 8888:8888 \
    -e HUGGINGFACE_TOKEN="$HUGGINGFACE_TOKEN" \
    -e MODELS="CompVis/stable-diffusion-v1-4\nrunwayml/stable-diffusion-v1-5" \
    --rm myrepo/comfyui-runpod:latest

What the container does on start
- If MODELS is set, runs `/download_models.sh` to prefetch models into `/models`.
- Starts JupyterLab on port 8888 (no token by default inside controlled environments).
- Starts ComfyUI on port 8188.

Next steps / optional improvements
- Use a non-root user for runtime and adjust file permissions.
- Add a lightweight process manager (supervisord) if you want more robust process handling.
- Add a CI workflow to build multi-arch artifact and push to a registry from GitHub Actions.

Files added
- `Dockerfile` - multi-stage Dockerfile
- `src/start_script.sh` - entrypoint that starts downloader, JupyterLab and ComfyUI
- `src/download_models.sh` - helper to download models from HF/URLs
- `README.md` - build/run notes and Mac M2 guidance

If you want, I can:
- Add a small GitHub Actions workflow to build the image on x86_64 and push to Docker Hub/Registry.
- Wire up automatic download of the specific workflows you attached and ensure they are loaded on ComfyUI startup.


