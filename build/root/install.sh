#!/bin/bash

# exit script if return code != 0
set -e

APPNAME="${1:-minecraftbedrockserver}"
RELEASETAG="${2:-latest}"
TARGETARCH="${3:-amd64}"
BEDROCK_URL="${4:-}"
BEDROCK_SHA256="${5:-}"
GOTTY_VERSION="${6:-v1.8.0}"

if [[ -z "${APPNAME}" ]]; then
	echo "[warn] App name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36'

pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
	awk \
	ca-certificates \
	catatonit \
	curl \
	grep \
	gzip \
	jq \
	moreutils \
	openssl \
	procps-ng \
	rsync \
	screen \
	sed \
	shadow \
	supervisor \
	tar \
	unzip \
	which

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

# Resolve Bedrock dedicated server download when the workflow did not pass an
# explicit URL. Prefer Microsoft's live download API for "latest" (same source
# as the official download page); fall back to EndstoneMC for pinned versions.
if [[ -z "${BEDROCK_URL}" ]]; then
	ms_api='https://net-secondary.web.minecraft-services.net/api/v1.0/download/links'
	if [[ "${RELEASETAG}" == "latest" ]]; then
		echo "[info] BEDROCK_URL not set, resolving latest download from Microsoft..."
		BEDROCK_URL="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${user_agent}" \
			"${ms_api}" | jq -r '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl')"
		if [[ -z "${BEDROCK_URL}" || "${BEDROCK_URL}" == "null" ]]; then
			echo "[warn] Microsoft download API did not return serverBedrockLinux, exiting script..."
			exit 1
		fi
		raw_version="$(basename "${BEDROCK_URL}" | sed -n 's/^bedrock-server-\([0-9.]*\)\.zip$/\1/p')"
		if [[ -z "${raw_version}" ]]; then
			echo "[warn] Unable to parse Bedrock version from ${BEDROCK_URL}, exiting script..."
			exit 1
		fi
		# Match Endstone-style tags: 1.26.52.3 -> 1.26.52
		RELEASETAG="$(echo "${raw_version}" | awk -F. '{print $1 "." $2 "." $3}')"
		echo "[info] Resolved latest Bedrock ${RELEASETAG} (${BEDROCK_URL})"
	else
		echo "[info] BEDROCK_URL not set, resolving ${RELEASETAG} from EndstoneMC/bedrock-server-data..."
		data_branch="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${user_agent}" \
			'https://api.github.com/repos/EndstoneMC/bedrock-server-data' | jq -r '.default_branch')"
		if [[ -z "${data_branch}" || "${data_branch}" == "null" ]]; then
			echo "[warn] Unable to resolve EndstoneMC/bedrock-server-data default branch, falling back to v2"
			data_branch="v2"
		fi

		metadata="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${user_agent}" \
			"https://raw.githubusercontent.com/EndstoneMC/bedrock-server-data/${data_branch}/release/${RELEASETAG}/metadata.json")"
		BEDROCK_URL="$(echo "${metadata}" | jq -r '.binary.linux.url')"
		BEDROCK_SHA256="$(echo "${metadata}" | jq -r '.binary.linux.sha256')"
	fi
fi

if [[ -z "${BEDROCK_URL}" || "${BEDROCK_URL}" == "null" ]]; then
	echo "[warn] Bedrock download URL is empty, exiting script..."
	exit 1
fi

echo -e "export APPNAME=${APPNAME}\nexport IMAGE_RELEASE_TAG=${RELEASETAG}\nexport TARGETARCH=${TARGETARCH}\n" >> '/etc/image-build-info'

# github packages
####

download_path="/tmp/gotty"
install_path="/usr/bin"
mkdir -p "${download_path}" "${install_path}"

gotty_asset="gotty_${GOTTY_VERSION}_linux_${TARGETARCH}.tar.gz"
gotty_url="https://github.com/sorenisanerd/gotty/releases/download/${GOTTY_VERSION}/${gotty_asset}"
echo "[info] Downloading gotty from '${gotty_url}'"
curl -fL --retry 5 --retry-delay 2 --user-agent "${user_agent}" -o "${download_path}/${gotty_asset}" "${gotty_url}"
tar -xvf "${download_path}/${gotty_asset}" -C "${install_path}"
chmod +x "${install_path}/gotty"

# custom
####

echo "[info] Downloading Bedrock dedicated server from '${BEDROCK_URL}'"
curl -fL --retry 12 --retry-delay 10 --connect-timeout 5 --max-time 600 \
	--user-agent "${user_agent}" \
	-o "/tmp/minecraftbedrockserver.zip" \
	"${BEDROCK_URL}"

if [[ -n "${BEDROCK_SHA256}" && "${BEDROCK_SHA256}" != "null" ]]; then
	echo "[info] Verifying Bedrock zip SHA256..."
	echo "${BEDROCK_SHA256}  /tmp/minecraftbedrockserver.zip" | sha256sum -c -
fi

mkdir -p "/srv/minecraft"
unzip "/tmp/minecraftbedrockserver.zip" -d "/srv/minecraft"
chmod +x "/srv/minecraft/bedrock_server"

# container perms
####

install_paths="/srv /home/nobody /config"
mkdir -p /config /home/nobody

# enable mouse and keyboard scrolling for screen
cat <<'EOF' > /home/nobody/.screenrc
# Enable mouse scrolling and scroll bar history scrolling
termcapinfo xterm* ti@:te@
EOF

# confirm path(s) exist, if not then exit
for i in ${install_paths}; do
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..."
		exit 1
	fi
done

chmod -R 775 ${install_paths}

if getent group users >/dev/null; then
	:
else
	groupadd users
fi

usermod -g users nobody
usermod -a -G nobody nobody
usermod -d /home/nobody nobody
usermod --expiredate= nobody
usermod -s /bin/bash nobody
chown -R nobody:users /home/nobody /srv /config

echo "export install_paths=\"${install_paths}\"" >> '/etc/image-build-info'

# cleanup
####

yes | pacman -Scc || true
rm -rf /var/cache/pacman/pkg/* /tmp/* /usr/share/man/*
