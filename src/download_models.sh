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
MANDATORY_DOWNLOADS=(
  "models/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors?download=true|true"
  "models/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors?download=true|true"
  "models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true|true"
  "models/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true|true"
  "models/loras/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors?download=true|true"
  "models/loras/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors?download=true|true"
  "models/loras/wan2.2/wan2.2-i2v-high-oral-insertion-v1.0.safetensors|https://huggingface.co/rahul7star/wan2.2Lora/resolve/main/wan2.2/wan2.2-i2v-high-oral-insertion-v1.0.safetensors?download=true|true"
  "models/loras/wan2.2/wan2.2-i2v-low-oral-insertion-v1.0.safetensors|https://huggingface.co/rahul7star/wan2.2Lora/resolve/main/wan2.2/wan2.2-i2v-low-oral-insertion-v1.0.safetensors?download=true|true"
  "custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife49.pth|https://huggingface.co/hfmaster/models-moved/resolve/main/rife/rife49.pth?download=true|false"
  "ComfyUI/models/diffusion_models/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors|https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/T2V/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors?download=true|true"
  "ComfyUI/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true|true"
  "ComfyUI/models/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true|true"
  "ComfyUI/models/loras/wan/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors?download=true|true"
  "ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors?download=true|true"
  "ComfyUI/models/unet/Qwen_Image_Edit-Q8_0.gguf|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/unet/Qwen_Image_Edit-Q8_0.gguf?download=true|true"
  "ComfyUI/models/vae/qwen_image_vae.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors?download=true|true"
  "ComfyUI/models/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors?download=true|true"
)

failures=0
for entry in "${MANDATORY_DOWNLOADS[@]}"; do
  IFS='|' read -r relpath url need_token <<<"$entry"
  # Resolve target path: if relpath starts with 'ComfyUI/' or 'models/' treat relative to COMFY_ROOT when COMFY_ROOT contains ComfyUI
  if [[ "$relpath" == ComfyUI/* ]] && [ -d "$COMFY_ROOT" ]; then
    target="$COMFY_ROOT/${relpath#ComfyUI/}"
  else
    # If relpath already starts with ComfyUI, but COMFY_ROOT is not a ComfyUI folder, strip and place under OUTDIR
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
