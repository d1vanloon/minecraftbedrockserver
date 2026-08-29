#!/usr/bin/env bash
# Ensure a Docker daemon is running and ready.
#
# Cloud Agent VMs are nested containers without systemd, so the daemon is
# launched directly and uses the fuse-overlayfs storage driver (the native
# overlay driver cannot mount inside the nested container).
set -euo pipefail

DOCKERD_LOG="${DOCKERD_LOG:-/tmp/dockerd.log}"

configure_daemon() {
	sudo mkdir -p /etc/docker
	if [ ! -f /etc/docker/daemon.json ]; then
		echo '{
  "storage-driver": "fuse-overlayfs"
}' | sudo tee /etc/docker/daemon.json >/dev/null
	fi
}

wait_for_docker() {
	for _ in $(seq 1 30); do
		if sudo docker info >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	echo "[dockerd] daemon did not become ready in time; recent log:" >&2
	tail -n 40 "${DOCKERD_LOG}" >&2 || true
	return 1
}

ensure_dockerd() {
	if sudo docker info >/dev/null 2>&1; then
		echo "[dockerd] already running"
		return 0
	fi

	configure_daemon

	echo "[dockerd] starting daemon (logging to ${DOCKERD_LOG})"
	sudo sh -c "nohup dockerd >>'${DOCKERD_LOG}' 2>&1 &"

	wait_for_docker
	echo "[dockerd] ready"
}

# Allow running this file directly as well as sourcing it.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	ensure_dockerd
fi
