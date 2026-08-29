#!/usr/bin/env bash
# Per-boot startup for the Minecraft Bedrock server environment.
#
# Ensures the Docker daemon is running and (re)launches the server container
# with the web console enabled on port 8222.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${IMAGE_TAG:-minecraftbedrockserver:dev}"
CONTAINER_NAME="${CONTAINER_NAME:-minecraftbedrockserver}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dockerd.sh"
ensure_dockerd

if ! sudo docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
	echo "[start] Image ${IMAGE_TAG} not found; run .cursor/install.sh first" >&2
	exit 1
fi

echo "[start] (Re)starting container ${CONTAINER_NAME}"
sudo docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

sudo docker run -d \
	--name="${CONTAINER_NAME}" \
	-p 8222:8222/tcp \
	-p 19132:19132/udp \
	-p 19133:19133/udp \
	-e ENABLE_WEBUI_CONSOLE=yes \
	-e ENABLE_WEBUI_AUTH=yes \
	-e WEBUI_USER="${WEBUI_USER:-admin}" \
	-e WEBUI_PASS="${WEBUI_PASS:-minecraft}" \
	-e WEBUI_CONSOLE_TITLE="${WEBUI_CONSOLE_TITLE:-Minecraft Bedrock}" \
	-e CREATE_BACKUP_HOURS=0 \
	-e PURGE_BACKUP_DAYS=0 \
	-e UMASK=000 \
	-e PUID=0 \
	-e PGID=0 \
	"${IMAGE_TAG}"

echo "[start] Container running. Web console: http://localhost:8222 (user: ${WEBUI_USER:-admin})"
sudo docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}: {{.Status}} {{.Ports}}'
