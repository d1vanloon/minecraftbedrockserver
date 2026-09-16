#!/bin/bash
set -euo pipefail

IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/d1vanloon/minecraftbedrockserver}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-60}"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-900}"
CONFIRM_ATTEMPTS="${CONFIRM_ATTEMPTS:-12}"
CONFIRM_DELAY="${CONFIRM_DELAY:-5}"

if [[ -z "${UNRAID_API_URL:-}" ]]; then
	echo "UNRAID_API_URL is not set" >&2
	exit 1
fi
if [[ -z "${UNRAID_API_KEY:-}" ]]; then
	echo "UNRAID_API_KEY is not set" >&2
	exit 1
fi

api_url="${UNRAID_API_URL%/}"
if [[ "${api_url}" != */graphql ]]; then
	api_url="${api_url}/graphql"
fi

graphql() {
	local query="$1"
	local variables="$2"
	local max_time="${3:-${QUERY_TIMEOUT}}"
	local retry="${4:-}"
	local payload http_code body
	local -a curl_args=(
		-sS --show-error
		--connect-timeout 15 --max-time "${max_time}"
		-X POST "${api_url}"
		-H "Content-Type: application/json"
		-H "Accept: application/json"
		-H "x-api-key: ${UNRAID_API_KEY}"
	)

	if [[ "${retry}" == "retry" ]]; then
		curl_args+=(--retry 5 --retry-delay 5 --retry-all-errors)
	fi

	payload="$(jq -n --arg query "${query}" --arg variables "${variables}" \
		'{query: $query, variables: ($variables | fromjson)}')"
	if [[ -z "${payload}" ]]; then
		echo "Failed to build GraphQL payload" >&2
		exit 1
	fi

	body="$(mktemp)"
	http_code="$(curl "${curl_args[@]}" -o "${body}" -w '%{http_code}' --data "${payload}")"
	if [[ "${http_code}" != "200" ]]; then
		echo "Unraid API HTTP ${http_code}" >&2
		cat "${body}" >&2
		rm -f "${body}"
		exit 1
	fi
	if ! jq -e . "${body}" >/dev/null 2>&1; then
		echo "Unraid API did not return JSON" >&2
		cat "${body}" >&2
		rm -f "${body}"
		exit 1
	fi
	cat "${body}"
	rm -f "${body}"
}

fail_on_graphql_errors() {
	local response="$1"
	local context="$2"
	if echo "${response}" | jq -e '.errors != null and (.errors | length) > 0' >/dev/null; then
		echo "${context} GraphQL errors:" >&2
		echo "${response}" | jq '.errors' >&2
		exit 1
	fi
}

matching_containers() {
	local response="$1"
	echo "${response}" | jq -c --arg prefix "${IMAGE_PREFIX}" '
		[.data.docker.containers[]?
			| select(.image == $prefix or (.image | startswith($prefix + ":")))]
	'
}

not_running() {
	local containers="$1"
	echo "${containers}" | jq -c '
		[.[] | select(((.state // "") | ascii_upcase) != "RUNNING")]
	'
}

GET_CONTAINERS_QUERY='query GetContainers {
  docker {
    containers {
      id
      names
      image
      state
    }
  }
}'

UPDATE_CONTAINERS_QUERY='mutation UpdateContainers($ids: [PrefixedID!]!) {
  docker {
    updateContainers(ids: $ids) {
      id
      names
      state
      image
    }
  }
}'

echo "Querying Unraid Docker containers"
list_response="$(graphql "${GET_CONTAINERS_QUERY}" '{}' "${QUERY_TIMEOUT}" retry)"
fail_on_graphql_errors "${list_response}" "GetContainers"

matches="$(matching_containers "${list_response}")"
match_count="$(echo "${matches}" | jq 'length')"

if [[ "${match_count}" -eq 0 ]]; then
	echo "No Unraid containers found for image ${IMAGE_PREFIX}" >&2
	echo "${list_response}" | jq -r '.data.docker.containers[]? | "\(.image)\t\(.names | join(","))"' >&2
	exit 1
fi

echo "Found ${match_count} container(s) to update:"
echo "${matches}" | jq -r '.[] | "- \(.names | join(", ")) (\(.id)) image=\(.image) state=\(.state // "unknown")"'

ids="$(echo "${matches}" | jq -c '[.[].id]')"

echo "Updating containers via Unraid API"
update_response="$(graphql "${UPDATE_CONTAINERS_QUERY}" "$(jq -n --argjson ids "${ids}" '{ids: $ids}')" "${UPDATE_TIMEOUT}")"
fail_on_graphql_errors "${update_response}" "UpdateContainers"

updated="$(echo "${update_response}" | jq -c '.data.docker.updateContainers // []')"
updated_count="$(echo "${updated}" | jq 'length')"

if [[ "${updated_count}" -eq 0 ]]; then
	echo "UpdateContainers returned no containers" >&2
	echo "${update_response}" | jq . >&2
	exit 1
fi

echo "UpdateContainers returned:"
echo "${updated}" | jq -r '.[] | "- \(.names | join(", ")) state=\(.state // "unknown") image=\(.image)"'

confirm_matches="${updated}"
pending="$(not_running "${confirm_matches}")"
pending_count="$(echo "${pending}" | jq 'length')"

attempt=0
while [[ "${pending_count}" -gt 0 && "${attempt}" -lt "${CONFIRM_ATTEMPTS}" ]]; do
	attempt=$((attempt + 1))
	echo "Waiting for containers to reach RUNNING (${attempt}/${CONFIRM_ATTEMPTS})"
	echo "${pending}" | jq -r '.[] | "- \(.names | join(", ")) state=\(.state // "unknown")"'
	sleep "${CONFIRM_DELAY}"
	list_response="$(graphql "${GET_CONTAINERS_QUERY}" '{}' "${QUERY_TIMEOUT}" retry)"
	fail_on_graphql_errors "${list_response}" "GetContainers"
	confirm_matches="$(matching_containers "${list_response}")"
	pending="$(not_running "${confirm_matches}")"
	pending_count="$(echo "${pending}" | jq 'length')"
done

if [[ "${pending_count}" -gt 0 ]]; then
	echo "Containers were not RUNNING after update:" >&2
	echo "${pending}" | jq -r '.[] | "- \(.names | join(", ")) state=\(.state // "unknown")"' >&2
	exit 1
fi

echo "All matching Unraid containers are RUNNING:"
echo "${confirm_matches}" | jq -r '.[] | "- \(.names | join(", ")) state=\(.state // "unknown") image=\(.image)"'
