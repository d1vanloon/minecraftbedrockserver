#!/bin/bash

# exit script if return code != 0
set -e

mkdir -p /config
touch /config/supervisord.log

# redirect new file descriptors and then tee stdout & stderr to supervisor log and console
exec 3>&1 4>&2 &> >(tee -a /config/supervisord.log)

source '/etc/image-build-info'

echo "[info] Minecraft Bedrock Dedicated Server"
echo "[info] System information: $(uname -a)" | ts '%Y-%m-%d %H:%M:%.S'
echo "[info] Image architecture: '${TARGETARCH}'" | ts '%Y-%m-%d %H:%M:%.S'
echo "[info] Application name: '${APPNAME}'" | ts '%Y-%m-%d %H:%M:%.S'
echo "[info] Application image release tag: '${IMAGE_RELEASE_TAG}'" | ts '%Y-%m-%d %H:%M:%.S'

export PUID=$(echo "${PUID}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${PUID}" ]]; then
	echo "[info] PUID defined as '${PUID}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] PUID not defined (via -e PUID), defaulting to '99'" | ts '%Y-%m-%d %H:%M:%.S'
	export PUID="99"
fi

current_uid=$(id -u nobody)
if [[ "${current_uid}" != "${PUID}" ]]; then
	echo "[info] Executing usermod for PUID '${PUID}'..." | ts '%Y-%m-%d %H:%M:%.S'
	usermod -o -u "${PUID}" nobody &>/dev/null
	echo "[info] usermod completed successfully" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] User 'nobody' already has UID '${PUID}', skipping usermod" | ts '%Y-%m-%d %H:%M:%.S'
fi

export PGID=$(echo "${PGID}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${PGID}" ]]; then
	echo "[info] PGID defined as '${PGID}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[warn] PGID not defined (via -e PGID), defaulting to '100'" | ts '%Y-%m-%d %H:%M:%.S'
	export PGID="100"
fi

if getent group users >/dev/null; then
	current_gid=$(getent group users | cut -d: -f3)
	if [[ "${current_gid}" != "${PGID}" ]]; then
		echo "[info] Executing groupmod for PGID '${PGID}'..." | ts '%Y-%m-%d %H:%M:%.S'
		groupmod -o -g "${PGID}" users &>/dev/null
		echo "[info] groupmod completed successfully" | ts '%Y-%m-%d %H:%M:%.S'
	else
		echo "[info] Group 'users' already has GID '${PGID}', skipping groupmod" | ts '%Y-%m-%d %H:%M:%.S'
	fi
else
	echo "[info] Creating group 'users' with GID '${PGID}'..." | ts '%Y-%m-%d %H:%M:%.S'
	groupadd -o -g "${PGID}" users
fi

if [[ ! -z "${UMASK}" ]]; then
	echo "[info] UMASK defined as '${UMASK}'" | ts '%Y-%m-%d %H:%M:%.S'
	sed -i -e "s~umask.*~umask = ${UMASK}~g" /etc/supervisor/conf.d/*.conf
else
	echo "[warn] UMASK not defined (via -e UMASK), defaulting to '000'" | ts '%Y-%m-%d %H:%M:%.S'
	sed -i -e "s~umask.*~umask = 000~g" /etc/supervisor/conf.d/*.conf
fi

if [[ ! -f "/config/perms.txt" ]]; then
	if [[ -d "/config" ]]; then
		echo "[info] Setting ownership and permissions recursively on '/config'..." | ts '%Y-%m-%d %H:%M:%.S'
		set +e
		chown -R "${PUID}":"${PGID}" "/config"
		exit_code_chown=$?
		chmod -R 775 "/config"
		exit_code_chmod=$?
		set -e
		if (( exit_code_chown != 0 || exit_code_chmod != 0 )); then
			echo "[warn] Unable to chown/chmod '/config', assuming SMB mountpoint" | ts '%Y-%m-%d %H:%M:%.S'
		else
			echo "[info] Successfully set ownership and permissions on '/config'" | ts '%Y-%m-%d %H:%M:%.S'
		fi
	else
		echo "[fatal] '/config' directory does not exist, exiting script..." | ts '%Y-%m-%d %H:%M:%.S'
		exit 1
	fi

	echo "This file prevents ownership and permissions from being applied/re-applied to '/config', if you want to reset ownership and permissions then please delete this file and restart the container." > /config/perms.txt
else
	echo "[info] Permissions file '/config/perms.txt' exists, skipping setting ownership and permissions on '/config'" | ts '%Y-%m-%d %H:%M:%.S'
fi

disk_usage_tmp=$(du -s /tmp | awk '{print $1}')
if [ "${disk_usage_tmp}" -gt 1073741824 ]; then
	echo "[warn] /tmp directory contains 1GB+ of data, skipping clear down as this maybe mounted media" | ts '%Y-%m-%d %H:%M:%.S'
	echo "[info] Showing contents of /tmp..." | ts '%Y-%m-%d %H:%M:%.S'
	ls -al /tmp
else
	echo "[info] Deleting files in /tmp (non recursive)..." | ts '%Y-%m-%d %H:%M:%.S'
	rm -f /tmp/* > /dev/null 2>&1 || true
	rm -rf /tmp/tmux*
fi

source /usr/local/bin/envvars.sh

if [[ -n "${install_paths}" ]]; then
	previous_puid=$(cat "/root/puid" 2>/dev/null || true)
	previous_pgid=$(cat "/root/pgid" 2>/dev/null || true)

	if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "${previous_puid}" != "${PUID}" || "${previous_pgid}" != "${PGID}" ]]; then
		for path in ${install_paths}; do
			if [[ -d "${path}" ]]; then
				chown -R "${PUID}":"${PGID}" "${path}"
			fi
		done
	fi

	echo "${PUID}" > /root/puid
	echo "${PGID}" > /root/pgid
fi

chmod 666 "/config/supervisord.log"

echo "[info] Starting Supervisor..." | ts '%Y-%m-%d %H:%M:%.S'

exec 1>&3 2>&4

exec /usr/bin/supervisord -c /etc/supervisord.conf -n
