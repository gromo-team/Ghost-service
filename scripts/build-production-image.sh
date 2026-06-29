#!/usr/bin/env bash
#
# Build the Ghost production Docker image from this monorepo.
#
# Dockerfile.production does NOT build against the raw source tree — it expects
# the packed `ghost/core` output as its build context (the same thing CI does).
# This script reproduces those steps end to end.
#
# Usage:
#   ./scripts/build-production-image.sh [IMAGE_TAG]
#
# Example:
#   ./scripts/build-production-image.sh myregistry.azurecr.io/ghost:6.48.1
#
set -euo pipefail

IMAGE_TAG="${1:-ghost-service:local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT_DIR="$(mktemp -d)/ghost-production"

cd "$REPO_ROOT"

echo "==> 1/5 Enable corepack (pinned pnpm)"
corepack enable

echo "==> 2/5 Install deps + initialize theme submodules (casper/source)"
# This is the step that was missing — without it, content/themes/casper is
# empty and the Docker build dies on: cp: cannot stat 'content/themes/casper'
pnpm install --frozen-lockfile
git submodule update --init --recursive

echo "==> 3/5 Build server + admin assets (production)"
PKG_VERSION="$(node -p "require('./ghost/core/package.json').version")"
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
export GHOST_BUILD_VERSION="${PKG_VERSION}+${SHORT_SHA}"
pnpm build:production

echo "==> 4/5 Pack ghost/core into a clean build context"
pnpm --filter ghost archive          # produces ghost/core/package/
rm -rf "$CONTEXT_DIR"
mkdir -p "$(dirname "$CONTEXT_DIR")"
mv ghost/core/package "$CONTEXT_DIR"

echo "==> 5/5 Build Docker image (target: full = server + admin)"
docker build \
  --load \
  -f Dockerfile.production \
  --target full \
  --build-arg NODE_VERSION=22.18.0 \
  --build-arg GHOST_BUILD_VERSION="${GHOST_BUILD_VERSION}" \
  -t "${IMAGE_TAG}" \
  "$CONTEXT_DIR"

echo "==> Done: ${IMAGE_TAG}"
echo "    Smoke test: docker run --rm -e NODE_ENV=development -p 2368:2368 ${IMAGE_TAG}"
