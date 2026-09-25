#!/bin/bash
# Resolve the current Minecraft Bedrock Dedicated Server download.
#
# Primary source: Microsoft Minecraft Services download links API
#   https://net-secondary.web.minecraft-services.net/api/v1.0/download/links
# This is the same endpoint the official download page and EndstoneMC use.
# Unlike EndstoneMC/bedrock-server-data (updated once daily), this API
# reflects new Bedrock server builds as soon as Mojang publishes them.
#
# Historical / pinned versions still fall back to EndstoneMC metadata when
# REQUESTED_VERSION is set to a specific release that is not the live latest.
set -euo pipefail

CHANNEL="${CHANNEL:-release}"
REQUESTED_VERSION="${REQUESTED_VERSION:-}"
COMPUTE_SHA256="${COMPUTE_SHA256:-false}"
DATA_REPO="${DATA_REPO:-EndstoneMC/bedrock-server-data}"
MS_DOWNLOAD_API="${MS_DOWNLOAD_API:-https://net-secondary.web.minecraft-services.net/api/v1.0/download/links}"
USER_AGENT="${USER_AGENT:-Mozilla/5.0 (compatible; minecraftbedrockserver-ci/1.0)}"

auth_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

download_type_for_channel() {
	case "${1}" in
		release) echo "serverBedrockLinux" ;;
		preview) echo "serverBedrockPreviewLinux" ;;
		*)
			echo "Unsupported CHANNEL=${1} (expected release or preview)" >&2
			exit 1
			;;
	esac
}

# Normalize zip version (e.g. 1.26.52.3 / 1.26.60.28) to Endstone-compatible
# keys: 1.26.52 or 1.26.60-preview.28
normalize_version() {
	local raw="$1"
	local channel="$2"
	local major minor patch build
	IFS=. read -r major minor patch build <<<"${raw}"
	if [[ -z "${major}" || -z "${minor}" || -z "${patch}" ]]; then
		echo "Unable to parse Bedrock version from '${raw}'" >&2
		exit 1
	fi
	if [[ "${channel}" == "preview" ]]; then
		if [[ -z "${build}" ]]; then
			echo "Preview version '${raw}' is missing a build component" >&2
			exit 1
		fi
		echo "${major}.${minor}.${patch}-preview.${build}"
	else
		echo "${major}.${minor}.${patch}"
	fi
}

extract_raw_version_from_url() {
	local url="$1"
	local filename
	filename="$(basename "${url}")"
	if [[ "${filename}" =~ bedrock-server-([0-9]+(\.[0-9]+){2,3})\.zip ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo "Unable to extract version from URL: ${url}" >&2
		exit 1
	fi
}

resolve_from_microsoft() {
	local download_type links_json url raw_version version
	download_type="$(download_type_for_channel "${CHANNEL}")"
	links_json="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${USER_AGENT}" \
		"${MS_DOWNLOAD_API}")"
	url="$(echo "${links_json}" | jq -r --arg type "${download_type}" \
		'.result.links[] | select(.downloadType == $type) | .downloadUrl')"
	if [[ -z "${url}" || "${url}" == "null" ]]; then
		echo "Microsoft download API did not return ${download_type}" >&2
		exit 1
	fi
	raw_version="$(extract_raw_version_from_url "${url}")"
	version="$(normalize_version "${raw_version}" "${CHANNEL}")"
	echo "${version}"$'\t'"${url}"$'\t'"${raw_version}"
}

resolve_from_endstone() {
	local requested="$1"
	local data_branch versions_json metadata_json url sha256 version

	data_branch="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${USER_AGENT}" \
		"${auth_args[@]}" \
		"https://api.github.com/repos/${DATA_REPO}" | jq -r '.default_branch')"
	if [[ -z "${data_branch}" || "${data_branch}" == "null" ]]; then
		echo "Unable to resolve default branch for ${DATA_REPO}, falling back to v2" >&2
		data_branch="v2"
	fi

	if [[ -z "${requested}" || "${requested}" == "latest" ]]; then
		versions_json="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${USER_AGENT}" \
			"https://raw.githubusercontent.com/${DATA_REPO}/${data_branch}/versions.json")"
		version="$(echo "${versions_json}" | jq -r ".${CHANNEL}.latest")"
	else
		version="${requested}"
	fi

	if [[ -z "${version}" || "${version}" == "null" ]]; then
		echo "Unable to resolve ${CHANNEL} version from ${DATA_REPO}" >&2
		exit 1
	fi

	metadata_json="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${USER_AGENT}" \
		"https://raw.githubusercontent.com/${DATA_REPO}/${data_branch}/${CHANNEL}/${version}/metadata.json")"
	url="$(echo "${metadata_json}" | jq -r '.binary.linux.url')"
	sha256="$(echo "${metadata_json}" | jq -r '.binary.linux.sha256')"

	if [[ -z "${url}" || "${url}" == "null" ]]; then
		echo "Unable to resolve linux download URL for ${CHANNEL} ${version}" >&2
		exit 1
	fi

	echo "${version}"$'\t'"${url}"$'\t'"${sha256}"$'\t'"${data_branch}"
}

compute_sha256() {
	local url="$1"
	local tmp
	tmp="$(mktemp)"
	curl -fL --retry 12 --retry-delay 10 --connect-timeout 5 --max-time 600 \
		--user-agent "${USER_AGENT}" -o "${tmp}" "${url}"
	sha256sum "${tmp}" | awk '{print $1}'
	rm -f "${tmp}"
}

version=""
url=""
sha256=""
raw_version=""
data_branch=""
source=""

want_latest="false"
if [[ -z "${REQUESTED_VERSION}" || "${REQUESTED_VERSION}" == "latest" ]]; then
	want_latest="true"
fi

if [[ "${want_latest}" == "true" ]]; then
	IFS=$'\t' read -r version url raw_version < <(resolve_from_microsoft)
	source="microsoft"
	sha256=""
	if [[ "${COMPUTE_SHA256}" == "true" ]]; then
		echo "Computing SHA256 for ${url}" >&2
		sha256="$(compute_sha256 "${url}")"
	fi
else
	# Pinned versions require historical metadata; Microsoft only exposes latest.
	IFS=$'\t' read -r version url sha256 data_branch < <(resolve_from_endstone "${REQUESTED_VERSION}")
	source="endstone"
	if [[ "${sha256}" == "null" ]]; then
		sha256=""
	fi
	if [[ -z "${sha256}" && "${COMPUTE_SHA256}" == "true" ]]; then
		echo "Computing SHA256 for ${url}" >&2
		sha256="$(compute_sha256 "${url}")"
	fi
fi

major_minor="$(echo "${version}" | awk -F'[.-]' '{print $1 "." $2}')"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "version=${version}"
		echo "url=${url}"
		echo "sha256=${sha256}"
		echo "major_minor=${major_minor}"
		echo "source=${source}"
		if [[ -n "${data_branch}" ]]; then
			echo "data_branch=${data_branch}"
		fi
		if [[ -n "${raw_version}" ]]; then
			echo "raw_version=${raw_version}"
		fi
	} >> "${GITHUB_OUTPUT}"
fi

echo "Resolved ${CHANNEL} ${version} via ${source} (${url})"
