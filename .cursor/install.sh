#!/usr/bin/env bash
# Idempotent Cloud Agent setup for the Minecraft Bedrock server image.
#
# Installs Docker Engine (with the fuse-overlayfs storage driver required by the
# nested-container VM) and builds the application image from the repository
# Dockerfile so it is ready to run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-minecraftbedrockserver:dev}"

install_docker() {
	if command -v docker >/dev/null 2>&1 && command -v fuse-overlayfs >/dev/null 2>&1; then
		echo "[install] Docker and fuse-overlayfs already present"
		return 0
	fi

	echo "[install] Installing Docker Engine and fuse-overlayfs"
	export DEBIAN_FRONTEND=noninteractive
	sudo apt-get update -qq
	sudo apt-get install -y -qq ca-certificates curl gnupg

	sudo install -m 0755 -d /etc/apt/keyrings
	if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
			| sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
		sudo chmod a+r /etc/apt/keyrings/docker.gpg
	fi

	# shellcheck disable=SC1091
	. /etc/os-release
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
		| sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

	sudo apt-get update -qq
	# --force-confold keeps existing conffiles so a fuse3 prompt cannot block install.
	sudo apt-get install -y -qq \
		-o Dpkg::Options::=--force-confold \
		docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin fuse-overlayfs

	# Convenience: let the agent user talk to the daemon without sudo in new shells.
	sudo usermod -aG docker "$(id -un)" || true
}

install_docker

# Bring up the daemon so the image can be built.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dockerd.sh"
ensure_dockerd

echo "[install] Building ${IMAGE_TAG} from ${REPO_ROOT}/Dockerfile"
sudo docker build -t "${IMAGE_TAG}" "${REPO_ROOT}"

echo "[install] Done. Image ready:"
sudo docker images "${IMAGE_TAG}"
