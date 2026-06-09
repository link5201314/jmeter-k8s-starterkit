#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./docker/jmeter-ctg/build_and_push.sh <image-repo> <tag> [jolokia-version]
# Example:
#   ./docker/jmeter-ctg/build_and_push.sh docker.io/isaac0815/jmeter-k8s-base 5.6.3-ctg-1
#   ./docker/jmeter-ctg/build_and_push.sh docker.io/isaac0815/jmeter-k8s-base 5.6.3-ctg-2 2.2.9

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <image-repo> <tag>"
  exit 1
fi

IMAGE_REPO="$1"
TAG="$2"
JOLOKIA_VERSION="${3:-2.2.9}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKERFILE_PATH="$SCRIPT_DIR/Dockerfile"

if [[ ! -f "$DOCKERFILE_PATH" ]]; then
  echo "Dockerfile not found: $DOCKERFILE_PATH"
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "podman command not found. Please install podman first."
  exit 1
fi

echo "[INFO] Building image $IMAGE_REPO:$TAG"
echo "[INFO] Jolokia version: $JOLOKIA_VERSION"
podman build \
  -f "$DOCKERFILE_PATH" \
  --build-arg JOLOKIA_VERSION="$JOLOKIA_VERSION" \
  -t "$IMAGE_REPO:$TAG" \
  "$ROOT_DIR"

echo "[INFO] Pushing image $IMAGE_REPO:$TAG"
podman push "$IMAGE_REPO:$TAG"

echo "[INFO] Done"
echo "[INFO] Remember to update helm values for both master/slave image tag."
