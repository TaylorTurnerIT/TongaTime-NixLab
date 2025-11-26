#!/usr/bin/env bash
# build-deployer.sh

IMAGE_NAME="homelab-deployer"
IMAGE_TAG="latest"

echo "🔨 Building deployment container..."

podman build \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" \
  -f Containerfile \
  .

echo "✅ Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "📊 Image size:"
podman images "${IMAGE_NAME}:${IMAGE_TAG}"