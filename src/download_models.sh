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

# Determine ComfyUI root for the explicit ComfyUI-prefixed download paths.
COMFY_ROOT=${COMFY_ROOT:-}
if [ -z "$COMFY_ROOT" ]; then
  if [ -d "/ComfyUI" ]; then
    COMFY_ROOT=/ComfyUI
  elif [ -d "/workspace/ComfyUI" ]; then
    COMFY_ROOT=/workspace/ComfyUI
  elif [ -d "./ComfyUI" ]; then
    COMFY_ROOT=./ComfyUI
  else
    # fallback to OUTDIR if ComfyUI not present
    COMFY_ROOT="$OUTDIR"
  fi
fi

echo "Using COMFY_ROOT=$COMFY_ROOT"

# Helper to perform a robust download to an exact target path.
download_to() {
  local target="$1" url="$2" use_hf_token="${3:-false}"
  mkdir -p "$(dirname "$target")"
  if [ -s "$target" ]; then
    echo "Already present, skipping: $target"
    return 0
  fi
  echo "Downloading -> $target"
  # prefer aria2c, otherwise curl, otherwise wget
  local headers=()
  if [ "$use_hf_token" = "true" ] && [ -n "${HUGGINGFACE_TOKEN-}" ]; then
    headers+=(--header "Authorization: Bearer ${HUGGINGFACE_TOKEN}")
  fi
  if command -v aria2c >/dev/null 2>&1; then
    # aria2c accepts --header for auth
    aria2c -x 16 -s 16 -d "$(dirname "$target")" -o "$(basename "$target")" "${headers[@]}" "$url" || {
      echo "aria2c failed for $url, trying curl"
    }
  fi
  if [ ! -s "$target" ]; then
    if command -v curl >/dev/null 2>&1; then
      if [ "${#headers[@]}" -gt 0 ]; then
        curl -L --retry 3 -o "$target" -H "Authorization: Bearer ${HUGGINGFACE_TOKEN}" "$url" || echo "curl failed for $url"
      else
        curl -L --retry 3 -o "$target" "$url" || echo "curl failed for $url"
      fi
    elif command -v wget >/dev/null 2>&1; then
      if [ "${#headers[@]}" -gt 0 ]; then
        wget -O "$target" --header="Authorization: Bearer ${HUGGINGFACE_TOKEN}" "$url" || echo "wget failed for $url"
      else
        wget -O "$target" "$url" || echo "wget failed for $url"
      fi
    else
      echo "No download tool (aria2c/curl/wget) available to fetch $url" >&2
      return 1
    fi
  fi
  if [ -s "$target" ]; then
    echo "Saved $target"
    return 0
  else
    echo "Failed to download $url to $target" >&2
    return 1
  fi
}

echo "Starting mandatory downloads (these are always fetched first)"

# List of mandatory downloads in the format: "<relative-target-path>|<url>|<use_hf_token true|false>"
# Relative paths are resolved against COMFY_ROOT when prefixed with 'ComfyUI/' or when the user intended the ComfyUI location.
# MANDATORY_DOWNLOADS=(
#   "models/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors?download=true|true"
#   "models/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors?download=true|true"
#   "models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true|true"
#   "models/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true|true"
#   "models/loras/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors?download=true|true"
#   "models/loras/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors?download=true|true"
#   "models/loras/wan2.2/wan2.2-i2v-high-oral-insertion-v1.0.safetensors|https://huggingface.co/rahul7star/wan2.2Lora/resolve/main/wan2.2/wan2.2-i2v-high-oral-insertion-v1.0.safetensors?download=true|true"
#   "models/loras/wan2.2/wan2.2-i2v-low-oral-insertion-v1.0.safetensors|https://huggingface.co/rahul7star/wan2.2Lora/resolve/main/wan2.2/wan2.2-i2v-low-oral-insertion-v1.0.safetensors?download=true|true"
#   "custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife49.pth|https://huggingface.co/hfmaster/models-moved/resolve/main/rife/rife49.pth?download=true|false"
#   "ComfyUI/models/diffusion_models/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors|https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/T2V/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors?download=true|true"
#   "ComfyUI/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true|true"
#   "ComfyUI/models/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true|true"
#   "ComfyUI/models/loras/wan/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors?download=true|true"
#   "ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors?download=true|true"
#   "ComfyUI/models/unet/Qwen_Image_Edit-Q8_0.gguf|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/unet/Qwen_Image_Edit-Q8_0.gguf?download=true|true"
#   "ComfyUI/models/vae/qwen_image_vae.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors?download=true|true"
#   "/ComfyUI/models/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors?download=true|true"
# )

MANDATORY_DOWNLOADS=(
  "models/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors?download=true|true"
  "models/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors?download=true|true"
  "models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true|true"
  "models/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true|true"
  "models/loras/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors?download=true|true"
  "models/loras/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors?download=true|true"
  "models/loras/wan2.2-i2v-high-oral-insertion-v1.0.safetensors|https://huggingface.co/rahul7star/wan2.2Lora/resolve/main/wan2.2/wan2.2-i2v-high-oral-insertion-v1.0.safetensors?download=true|true"
  "models/loras/wan2.2-i2v-low-oral-insertion-v1.0.safetensors|https://huggingface.co/rahul7star/wan2.2Lora/resolve/main/wan2.2/wan2.2-i2v-low-oral-insertion-v1.0.safetensors?download=true|true"
  "custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife49.pth|https://huggingface.co/hfmaster/models-moved/resolve/main/rife/rife49.pth?download=true|false"
  "ComfyUI/models/diffusion_models/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors|https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/T2V/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors?download=true|true"
  "ComfyUI/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true|true"
  "ComfyUI/models/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true|true"
  "ComfyUI/models/loras/wan/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors?download=true|true"
  "ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors?download=true|true"
  # "ComfyUI/models/unet/Qwen_Image_Edit-Q8_0.gguf|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/unet/Qwen_Image_Edit-Q8_0.gguf?download=true|true"
  "ComfyUI/models/vae/qwen_image_vae.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors?download=true|true"
  "ComfyUI/models/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors|https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Lightning-4steps-V1.0.safetensors?download=true|true"
  "ComfyUI/models/flux/flux1-dev-fp8-e4m3fn.safetensors|https://huggingface.co/Kijai/flux-fp8/resolve/main/flux1-dev-fp8-e4m3fn.safetensors?download=true|true"
  "ComfyUI/models/style_models/flux1-redux-dev.safetensors|https://huggingface.co/black-forest-labs/FLUX.1-Redux-dev/resolve/main/flux1-redux-dev.safetensors?download=true|true"
  "ComfyUI/models/flux/flux.1_dev-shakker_labs_union.safetensors|https://huggingface.co/Shakker-Labs/FLUX.1-dev-ControlNet-Union-Pro-2.0/resolve/main/diffusion_pytorch_model.safetensors?download=true|true"
  "ComfyUI/models/flux/flux.1_dev-jasperai_control_upscaler.safetensors|https://huggingface.co/jasperai/Flux.1-dev-Controlnet-Upscaler/resolve/main/diffusion_pytorch_model.safetensors?download=true|true"
  "ComfyUI/models/text_encoders/t5xxl_fp16.safetensors|https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors?download=true|true"
  "ComfyUI/models/text_encoders/clip_l.safetensors|https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors?download=true|true"
  "ComfyUI/models/clip_vision/sigclip_vision_patch14_384.safetensors|https://huggingface.co/Comfy-Org/sigclip_vision_384/resolve/main/sigclip_vision_patch14_384.safetensors?download=true|true"
  "ComfyUI/models/diffusion_models/Wan2_2-T2V-A14B_HIGH_fp8_e4m3fn_scaled_KJ.safetensors|https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/T2V/Wan2_2-T2V-A14B-HIGH_fp8_e4m3fn_scaled_KJ.safetensors?download=true|true"
  "/ComfyUI/models/ultralytics/bbox/face_yolov8m.pt|https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt?download=true|true"
  "/ComfyUI/models/ultralytics/segm/face_yolov8n-seg2_60.pt|https://github.com/hben35096/assets/releases/download/yolo8/face_yolov8n-seg2_60.pt|false"
  "/ComfyUI/models/controlnet/flux_shakker_labs_union_pro-fp8_e4m3fn.safetensors|https://huggingface.co/Kijai/flux-fp8/resolve/main/flux_shakker_labs_union_pro-fp8_e4m3fn.safetensors?download=true|true"
  "/ComfyUI/models/controlnet/flux.1-dev-controlnet-upscaler.safetensors|https://huggingface.co/jasperai/Flux.1-dev-Controlnet-Upscaler/resolve/main/diffusion_pytorch_model.safetensors?download=true|true"
  "/ComfyUI/models/vae/ae.safetensors|https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors?download=true|true"
  "/ComfyUI/models/diffusion_models/flux1-dev-fp8-e4m3fn.safetensors|https://huggingface.co/Kijai/flux-fp8/resolve/main/flux1-dev-fp8-e4m3fn.safetensors?download=true|true"
  "/ComfyUI/models/unet/Qwen_Image_Edit-Q8_0.gguf|https://huggingface.co/QuantStack/Qwen-Image-Edit-GGUF/resolve/main/Qwen_Image_Edit-Q8_0.gguf?download=true|true"
)

failures=0
for entry in "${MANDATORY_DOWNLOADS[@]}"; do
  IFS='|' read -r relpath url need_token <<<"$entry"
  # Resolve target path:
  # - If relpath is absolute (starts with '/'), use it as-is
  # - If it starts with 'ComfyUI/', resolve under COMFY_ROOT (or OUTDIR fallback)
  # - Otherwise, resolve relative to COMFY_ROOT
  if [[ "$relpath" == /* ]]; then
    target="$relpath"
  elif [[ "$relpath" == ComfyUI/* ]] && [ -d "$COMFY_ROOT" ]; then
    target="$COMFY_ROOT/${relpath#ComfyUI/}"
  else
    if [[ "$relpath" == ComfyUI/* ]]; then
      target="$OUTDIR/${relpath#ComfyUI/}"
    else
      target="$COMFY_ROOT/$relpath"
    fi
  fi
  if ! download_to "$target" "$url" "$need_token"; then
    echo "Mandatory download failed: $url -> $target" >&2
    failures=$((failures+1))
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "One or more mandatory downloads failed (count=$failures). Check logs and retry." >&2
  # do not exit - allow optional MODELS to proceed, but signal non-zero at end
fi

echo "Mandatory downloads finished. Now processing additional MODELS/MODELS_FILE if provided."

# ------------------------------------------------------------
# JoyCaptionAlpha Two + Florence2 + SigLIP bootstrap (idempotent)
# ------------------------------------------------------------
# This section uses Hugging Face Hub's Python API to snapshot specific repos
# into the expected ComfyUI folder structure so the related custom nodes
# (e.g., Joy Caption Two and ComfyUI-Florence2) work out of the box.
#
# Note: We support both HF_TOKEN and HUGGINGFACE_TOKEN environment variables.

# Resolve COMFY_ROOT from above and set key dirs
HF_TOKEN_EFFECTIVE=${HF_TOKEN:-${HUGGINGFACE_TOKEN:-}}
HF_HOME_DIR=${HF_HOME:-"$COMFY_ROOT/hf-cache"}
export HF_HOME="$HF_HOME_DIR"

JOY_DIR="$COMFY_ROOT/models/Joy_caption_two"
FLO_DIR="$COMFY_ROOT/models/florence2"
CLIP_DIR="$COMFY_ROOT/models/clip/siglip-so400m-patch14-384"
LLM_DIR="$COMFY_ROOT/models/LLM"

mkdir -p "$JOY_DIR" "$FLO_DIR" "$CLIP_DIR" "$LLM_DIR"

# Helper: Python-based snapshot download with optional repo_type and allow_patterns
hf_snapshot_dl() {
  local repo_id="$1" dest_dir="$2" repo_type="${3:-model}" allow_patterns="${4:-}"
  mkdir -p "$dest_dir"
  python - <<PY 2>/dev/null || true
from huggingface_hub import snapshot_download
import os
repo_id = """$repo_id"""
dest_dir = """$dest_dir"""
repo_type = """$repo_type"""
allow_patterns = """$allow_patterns""".strip() or None
hf_token = os.environ.get('HF_TOKEN') or os.environ.get('HUGGINGFACE_TOKEN') or None
home = os.environ.get('HF_HOME')
kwargs = {
    'repo_id': repo_id,
    'repo_type': repo_type,
    'local_dir': dest_dir,
    'local_dir_use_symlinks': False,
}
if allow_patterns:
    kwargs['allow_patterns'] = [p.strip() for p in allow_patterns.split(',') if p.strip()]
if home:
    kwargs['cache_dir'] = home
if hf_token:
    kwargs['token'] = hf_token
try:
    path = snapshot_download(**kwargs)
    print('Downloaded', repo_id, '->', dest_dir)
except Exception as e:
    print('WARN: snapshot_download failed for', repo_id, 'error=', e)
PY
}

# 0) Joy Caption Two base assets from the Space (exact steps, with status)
echo "[JoyCaption] Step 1/5: ensure destination folder (case-sensitive) -> $JOY_DIR"
mkdir -p "$JOY_DIR"

echo "[JoyCaption] Step 2/5: ensure HF CLI is available"
pip install -q -U "huggingface_hub[cli]" || true

echo "[JoyCaption] Step 3/5: download Space assets (cgrkzexw-599808/*)"
TMP_JOY="/tmp/joycaption_alpha_two"
rm -rf "$TMP_JOY" && mkdir -p "$TMP_JOY"
# Prefer new 'hf download', fallback to legacy 'huggingface-cli download'
if command -v hf >/dev/null 2>&1; then
  hf download fancyfeast/joy-caption-alpha-two \
    --repo-type space \
    --include "cgrkzexw-599808/*" \
    --local-dir "$TMP_JOY" \
    --resume-download >/dev/null 2>&1 || true
else
  huggingface-cli download fancyfeast/joy-caption-alpha-two \
    --repo-type space \
    --include "cgrkzexw-599808/*" \
    --local-dir "$TMP_JOY" \
    --resume-download --quiet || true
fi

# If the expected folder isn't present, try a generic Space snapshot and locate files dynamically
if [ ! -d "$TMP_JOY/cgrkzexw-599808" ] || [ ! -f "$TMP_JOY/cgrkzexw-599808/clip_model.pt" ]; then
  echo "[JoyCaption] Expected subfolder not found; attempting full Space snapshot and dynamic locate"
  hf_snapshot_dl "fancyfeast/joy-caption-alpha-two" "$TMP_JOY" "space"
fi

echo "[JoyCaption] Step 4/5: move files into $JOY_DIR"
joy_src=""
if [ -d "$TMP_JOY/cgrkzexw-599808" ] && [ -f "$TMP_JOY/cgrkzexw-599808/clip_model.pt" ]; then
  joy_src="$TMP_JOY/cgrkzexw-599808"
else
  joy_src=$(find "$TMP_JOY" -type f -name clip_model.pt -printf '%h\n' -quit 2>/dev/null || true)
fi
if [ -n "$joy_src" ]; then
  cp -an "$joy_src/." "$JOY_DIR/" 2>/dev/null || true
fi

echo "[JoyCaption] Step 5/5: verify contents"
ls -lh "$JOY_DIR" 2>/dev/null || true

# 1) Florence-2 model family (download into subfolders under models/florence2)
FLO_MODELS=(
  "microsoft/Florence-2-base"
  "microsoft/Florence-2-base-ft"
  "microsoft/Florence-2-large"
  "HuggingFaceM4/Florence-2-DocVQA"
  "thwri/CogFlorence-2.1-Large"
  "thwri/CogFlorence-2.2-Large"
  "gokaygokay/Florence-2-Flux-Large"
  "gokaygokay/Florence-2-SD3-Captioner"
  "MiaoshouAI/Florence-2-base-PromptGen-v1.5"
  "MiaoshouAI/Florence-2-large-PromptGen-v2.0"
  "PJMixers-Images/Florence-2-base-Castollux-v0.5"
)
for repo in "${FLO_MODELS[@]}"; do
  hf_snapshot_dl "$repo" "$FLO_DIR/$repo" "model"
done

# Register florence2 path for ComfyUI-Florence2 via extra_model_paths.yaml
EXTRA_YAML="$COMFY_ROOT/extra_model_paths.yaml"
python - <<PY 2>/dev/null || true
import os, yaml
extra = """$EXTRA_YAML"""
flo_dir = """$FLO_DIR"""
data = {}
if os.path.exists(extra):
    try:
        with open(extra, 'r') as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        data = {}
# ComfyUI expects values as newline-delimited strings, not lists
existing = data.get('florence2', '')
if isinstance(existing, str) and existing.strip():
    paths = [p for p in existing.split('\n') if p.strip()]
elif isinstance(existing, list):
    paths = [p for p in existing if isinstance(p, str) and p.strip()]
else:
    paths = []
if flo_dir not in paths:
    paths.append(flo_dir)
data['florence2'] = "\n".join(paths)
with open(extra, 'w') as f:
    yaml.safe_dump(data, f, sort_keys=False)
print('Registered florence2 path (newline string) ->', flo_dir)
PY

# 2) Joy Caption Two suggested LLMs (seed into HF cache so first run is faster)
LLM_MODELS=(
  "unsloth/Meta-Llama-3.1-8B-Instruct-bnb-4bit"
  "unsloth/Meta-Llama-3.1-8B-Instruct"
  "John6666/Llama-3.1-8B-Lexi-Uncensored-V2-nf4"
  "Orenguteng/Llama-3.1-8B-Lexi-Uncensored-V2"
)
for repo in "${LLM_MODELS[@]}"; do
  # Use HF cache dir; create a stable local_dir under cache
  cache_target="$HF_HOME_DIR/models--${repo//\//--}"
  hf_snapshot_dl "$repo" "$cache_target" "model"
done

# 3) SigLIP vision encoder for Joy Caption Two
hf_snapshot_dl "google/siglip-so400m-patch14-384" "$CLIP_DIR" "model"

# 4) Quick verification (non-fatal)
need_fix=0
for f in clip_model.pt image_adapter.pt config.yaml; do
  if [ ! -f "$JOY_DIR/$f" ]; then echo "[JoyCaption] MISSING $JOY_DIR/$f"; need_fix=1; fi
done
if [ ! -d "$JOY_DIR/text_model" ]; then echo "[JoyCaption] MISSING $JOY_DIR/text_model"; need_fix=1; fi
if [ "$need_fix" -eq 0 ]; then
  echo "Joy Caption Two base files present."
fi

# Load models from file if provided
if [ -n "${MODELS_FILE-}" ] && [ -f "${MODELS_FILE}" ]; then
  echo "Reading models from file: $MODELS_FILE"
  # read file into MODELS with newline separators
  MODELS=$(sed -e 's/\r$//' "$MODELS_FILE")
fi

if [ -z "${MODELS-}" ]; then
  echo "No MODELS variable set and no MODELS_FILE provided. Nothing else to download." >&2
  # exit with non-zero if mandatory downloads failed
  if [ "$failures" -ne 0 ]; then
    exit 2
  else
    exit 0
  fi
fi

echo "Models will be downloaded to: $OUTDIR"

# login to huggingface if token provided (non-fatal diagnostic)
if [ -n "${HUGGINGFACE_TOKEN-}" ]; then
  echo "HUGGINGFACE_TOKEN provided (not printed for security)."
fi

# Normalize separators: commas and semicolons -> newlines, keep existing newlines/spaces
# Replace commas/semicolons with newlines, then split on newlines and spaces
normalized=$(printf '%s' "$MODELS" | tr ',' '\n' | tr ';' '\n')

# iterate each non-empty trimmed entry; keep loop in current shell to retain counters
opt_failures=0
while IFS= read -r line; do
  m_trim=$(echo "$line" | tr -d '\r' | sed 's/^\s*//;s/\s*$//')
  if [ -z "$m_trim" ]; then
    continue
  fi
  echo "Processing: $m_trim"

  # If it looks like a huggingface id (owner/model), try snapshot_download
  if echo "$m_trim" | grep -qE '^[^/]+/[^/]+$'; then
    echo "Downloading HF model: $m_trim"
    python - <<PY || { echo "Failed to download HF model $m_trim (continuing)" >&2; opt_failures=$((opt_failures+1)); }
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
    # If file still missing/empty, count as failure but continue
    if [ ! -s "$OUTDIR/$(basename "$m_trim")" ]; then
      echo "Failed to download $m_trim (no file saved)" >&2
      opt_failures=$((opt_failures+1))
    fi
  fi
done <<< "$normalized"

echo "Downloads complete"

# If any failures occurred (mandatory or optional), return non-zero so callers can react
if [ "$failures" -ne 0 ] || [ "${opt_failures:-0}" -ne 0 ]; then
  echo "Completed with failures: mandatory=$failures optional=${opt_failures:-0}" >&2
  exit 2
fi
exit 0
