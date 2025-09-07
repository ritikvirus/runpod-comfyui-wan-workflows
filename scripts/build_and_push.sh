#!/usr/bin/env bash
set -euo pipefail

# Local helper to build using docker buildx and push to Docker Hub.
# Usage:
#   ./scripts/build_and_push.sh ritikvirus/comfyui-runpod
# You must be logged in to Docker Hub (docker login) before running.

REPO=${1:-ritikvirus/comfyui-runpod}
DATE_TAG=$(date +%m-%d)
TAG=${REPO}:${DATE_TAG}
LATEST=${REPO}:latest
DOCKERFILE=${2:-Dockerfile}

# Ensure buildx is available
if ! docker buildx version >/dev/null 2>&1; then
  echo "docker buildx not available. On macOS with recent Docker Desktop it should be present." >&2
  echo "If using Docker Desktop ensure BuildKit is enabled or install buildx." >&2
  exit 1
fi

# Create a builder instance if necessary
if ! docker buildx inspect --bootstrap >/dev/null 2>&1; then
  docker buildx create --use --name mybuilder || true
  docker buildx inspect --bootstrap
fi

# Build for linux/amd64 which Runpod expects
echo "Building image $TAG from $DOCKERFILE for linux/amd64"
docker buildx build --platform linux/amd64 -f "$DOCKERFILE" -t "$TAG" -t "$LATEST" --push .

echo "Pushed $TAG and $LATEST"
