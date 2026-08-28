#!/bin/bash
set -euo pipefail

CHANNEL="${CHANNEL:-release}"
REQUESTED_VERSION="${REQUESTED_VERSION:-}"
DATA_REPO="${DATA_REPO:-EndstoneMC/bedrock-server-data}"
USER_AGENT="${USER_AGENT:-Mozilla/5.0 (compatible; minecraftbedrockserver-ci/1.0)}"

auth_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

data_branch="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${USER_AGENT}" \
	"${auth_args[@]}" \
	"https://api.github.com/repos/${DATA_REPO}" | jq -r '.default_branch')"

if [[ -z "${data_branch}" || "${data_branch}" == "null" ]]; then
	echo "Unable to resolve default branch for ${DATA_REPO}, falling back to v2" >&2
	data_branch="v2"
fi

versions_json="$(curl -fsSL --retry 5 --retry-delay 2 --user-agent "${USER_AGENT}" \
	"https://raw.githubusercontent.com/${DATA_REPO}/${data_branch}/versions.json")"

if [[ -z "${REQUESTED_VERSION}" || "${REQUESTED_VERSION}" == "latest" ]]; then
	version="$(echo "${versions_json}" | jq -r ".${CHANNEL}.latest")"
else
	version="${REQUESTED_VERSION}"
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

major_minor="$(echo "${version}" | awk -F. '{print $1 "." $2}')"

{
	echo "version=${version}"
	echo "url=${url}"
	echo "sha256=${sha256}"
	echo "major_minor=${major_minor}"
	echo "data_branch=${data_branch}"
} >> "${GITHUB_OUTPUT}"

echo "Resolved ${CHANNEL} ${version} (${url})"
