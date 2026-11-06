#!/bin/bash
set -euo pipefail

IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/d1vanloon/minecraftbedrockserver}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-60}"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-900}"
CONFIRM_ATTEMPTS="${CONFIRM_ATTEMPTS:-12}"
CONFIRM_DELAY="${CONFIRM_DELAY:-5}"
# After a gateway timeout the host may still be pulling. Poll at this interval
# until the container is RUNNING with a new image, or UPDATE_TIMEOUT expires.
POLL_DELAY="${POLL_DELAY:-5}"

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

confirmed='[]'

graphql() {
	local query="$1"
	local variables="$2"
	local max_time="${3:-${QUERY_TIMEOUT}}"
	local retry="${4:-}"
	local allow_gateway="${5:-}"
	local payload http_code body curl_status
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
	curl_status=0
	http_code="$(curl "${curl_args[@]}" -o "${body}" -w '%{http_code}' --data "${payload}")" || curl_status=$?
	if [[ "${curl_status}" -ne 0 || -z "${http_code}" || "${http_code}" == "000" ]]; then
		echo "Unraid API request failed (curl status ${curl_status})" >&2
		if [[ -s "${body}" ]]; then
			cat "${body}" >&2
			echo >&2
		fi
		rm -f "${body}"
		if [[ "${allow_gateway}" == "allow-gateway-timeout" ]]; then
			return 2
		fi
		exit 1
	fi
	if [[ "${http_code}" != "200" ]]; then
		echo "Unraid API HTTP ${http_code}" >&2
		cat "${body}" >&2
		echo >&2
		rm -f "${body}"
		# 504 means the proxy gave up. Unraid may still be pulling and recreating.
		if [[ "${http_code}" == "504" && "${allow_gateway}" == "allow-gateway-timeout" ]]; then
			return 2
		fi
		exit 1
	fi
	if ! jq -e . "${body}" >/dev/null 2>&1; then
		echo "Unraid API did not return JSON" >&2
		cat "${body}" >&2
		echo >&2
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

running_containers() {
	local containers="$1"
	echo "${containers}" | jq -c '
		[.[] | select(((.state // "") | ascii_upcase) == "RUNNING")]
	'
}

container_record() {
	local containers="$1"
	local name="$2"
	echo "${containers}" | jq -c --arg name "${name}" '
		([.[] | select((.names // []) | map(ltrimstr("/")) | index($name))] | first // empty)
	'
}

container_image_changed() {
	local container="$1"
	local old_image_id="$2"
	local old_created="$3"
	echo "${container}" | jq -e \
		--arg old_image "${old_image_id}" \
		--arg old_created "${old_created}" '
		. != null
			and (
				(((.imageId // "") | tostring) != "" and ((.imageId | tostring) != $old_image))
				or (((.created // "") | tostring) != "" and ((.created | tostring) != $old_created))
			)
	' >/dev/null
}

append_confirmed() {
	local container="$1"
	confirmed="$(jq -c --argjson item "${container}" '. + [$item]' <<<"${confirmed}")"
}

fetch_container_response() {
	local response status=0
	# Command substitutions hide exit; fail the caller if the list query fails.
	response="$(graphql "${GET_CONTAINERS_QUERY}" '{}' "${QUERY_TIMEOUT}" retry)" || status=$?
	if [[ "${status}" -ne 0 ]]; then
		exit "${status}"
	fi
	fail_on_graphql_errors "${response}" "GetContainers"
	printf '%s\n' "${response}"
}

list_matches() {
	local response status=0
	response="$(fetch_container_response)" || status=$?
	if [[ "${status}" -ne 0 ]]; then
		exit "${status}"
	fi
	matching_containers "${response}"
}

remaining_budget() {
	echo $(( update_deadline - $(date +%s) ))
}

# A container that has not reappeared yet is reported as state=missing.
pending_line() {
	local name="$1"
	local container="$2"
	if [[ -z "${container}" ]]; then
		container="$(jq -nc --arg name "${name}" '{names:[$name], state:"missing"}')"
	fi
	echo "${container}" | jq -r '"- \(.names | join(", ")) state=\(.state // "unknown")"'
}

confirm_running() {
	local name="$1"
	local containers="$2"
	local attempt=0
	local container state

	while true; do
		container="$(container_record "${containers}" "${name}")"
		if [[ -n "${container}" ]]; then
			state="$(echo "${container}" | jq -r '(.state // "") | ascii_upcase')"
			if [[ "${state}" == "RUNNING" ]]; then
				append_confirmed "${container}"
				return 0
			fi
		fi
		if [[ "${attempt}" -ge "${CONFIRM_ATTEMPTS}" ]]; then
			echo "Updated containers were not RUNNING after update:" >&2
			pending_line "${name}" "${container}" >&2
			exit 1
		fi
		attempt=$((attempt + 1))
		echo "Waiting for ${name} to reach RUNNING (${attempt}/${CONFIRM_ATTEMPTS})"
		pending_line "${name}" "${container}"
		if [[ "${CONFIRM_DELAY}" -gt 0 ]]; then
			sleep "${CONFIRM_DELAY}"
		fi
		containers="$(list_matches)" || exit $?
	done
}

# After a gateway timeout the host may still be pulling. Keep polling until the
# container is RUNNING with a new imageId/created time, or the overall deadline
# expires. Do not start another update while the first may still be in flight.
poll_until_updated() {
	local name="$1"
	local old_image_id="$2"
	local old_created="$3"
	local matches container state status

	while true; do
		if [[ "$(remaining_budget)" -le 0 ]]; then
			echo "Timed out waiting for ${name} to finish updating" >&2
			exit 1
		fi
		status=0
		matches="$(list_matches)" || status=$?
		if [[ "${status}" -ne 0 ]]; then
			exit "${status}"
		fi
		container="$(container_record "${matches}" "${name}")"
		if [[ -n "${container}" ]] && container_image_changed "${container}" "${old_image_id}" "${old_created}"; then
			state="$(echo "${container}" | jq -r '(.state // "") | ascii_upcase')"
			if [[ "${state}" == "RUNNING" ]]; then
				append_confirmed "${container}"
				echo "${name} is RUNNING with an updated image"
				return 0
			fi
			echo "Waiting for ${name} to reach RUNNING (state=${state})"
		else
			echo "Waiting for ${name} image update to finish"
		fi
		if [[ "${POLL_DELAY}" -gt 0 ]]; then
			sleep "${POLL_DELAY}"
		else
			sleep 1
		fi
	done
}

update_one() {
	local id="$1"
	local name="$2"
	local old_image_id="$3"
	local old_created="$4"
	local update_status=0
	local update_response updated remaining

	remaining="$(remaining_budget)"
	if [[ "${remaining}" -le 0 ]]; then
		echo "Update timeout exceeded before updating ${name}" >&2
		exit 1
	fi
	echo "Updating ${name} via Unraid API"
	update_response="$(graphql "${UPDATE_CONTAINER_QUERY}" \
		"$(jq -n --arg id "${id}" '{id: $id}')" \
		"${remaining}" "" allow-gateway-timeout)" || update_status=$?
	if [[ "${update_status}" -eq 0 ]]; then
		fail_on_graphql_errors "${update_response}" "UpdateContainer"
		updated="$(echo "${update_response}" | jq -c '.data.docker.updateContainer // empty')"
		if [[ -z "${updated}" ]]; then
			echo "UpdateContainer returned no container for ${name}" >&2
			echo "${update_response}" | jq . >&2
			exit 1
		fi
		echo "UpdateContainer returned:"
		echo "${updated}" | jq -r '"- \(.names | join(", ")) state=\(.state // "unknown") image=\(.image) imageId=\(.imageId // "unknown")"'
		confirm_running "${name}" "$(jq -c '[.]' <<<"${updated}")"
		return 0
	fi
	if [[ "${update_status}" -eq 2 ]]; then
		echo "Gateway timed out updating ${name}; polling for the new image"
		poll_until_updated "${name}" "${old_image_id}" "${old_created}"
		return 0
	fi
	echo "UpdateContainer failed for ${name}" >&2
	exit 1
}

GET_CONTAINERS_QUERY='query GetContainers {
  docker {
    containers {
      id
      names
      image
      imageId
      created
      state
    }
  }
}'

UPDATE_CONTAINER_QUERY='mutation UpdateContainer($id: PrefixedID!) {
  docker {
    updateContainer(id: $id) {
      id
      names
      state
      image
      imageId
      created
    }
  }
}'

echo "Querying Unraid Docker containers"
list_response="$(fetch_container_response)"
matches="$(matching_containers "${list_response}")"
match_count="$(echo "${matches}" | jq 'length')"

if [[ "${match_count}" -eq 0 ]]; then
	echo "No Unraid containers found for image ${IMAGE_PREFIX}" >&2
	echo "${list_response}" | jq -r '.data.docker.containers[]? | "\(.image)\t\(.names | join(","))"' >&2
	exit 1
fi

echo "Found ${match_count} container(s) for image ${IMAGE_PREFIX}:"
echo "${matches}" | jq -r '.[] | "- \(.names | join(", ")) (\(.id)) image=\(.image) imageId=\(.imageId // "unknown") state=\(.state // "unknown")"'

targets="$(running_containers "${matches}")"
target_count="$(echo "${targets}" | jq 'length')"
skipped_count=$((match_count - target_count))

if [[ "${skipped_count}" -gt 0 ]]; then
	echo "Skipping ${skipped_count} stopped container(s)"
	echo "${matches}" | jq -r '.[] | select(((.state // "") | ascii_upcase) != "RUNNING") | "- \(.names | join(", ")) state=\(.state // "unknown")"'
fi

if [[ "${target_count}" -eq 0 ]]; then
	echo "No running Unraid containers to update for image ${IMAGE_PREFIX}"
	exit 0
fi

echo "Updating ${target_count} running container(s):"
echo "${targets}" | jq -r '.[] | "- \(.names | join(", ")) (\(.id)) image=\(.image) imageId=\(.imageId // "unknown") state=\(.state // "unknown")"'

update_deadline=$(( $(date +%s) + UPDATE_TIMEOUT ))

while IFS= read -r target; do
	id="$(echo "${target}" | jq -r '.id')"
	name="$(echo "${target}" | jq -r '.names[0] // "" | ltrimstr("/")')"
	old_image_id="$(echo "${target}" | jq -r '(.imageId // "") | tostring')"
	old_created="$(echo "${target}" | jq -r '(.created // "") | tostring')"
	if [[ -z "${name}" ]]; then
		echo "Container ${id} has no name" >&2
		exit 1
	fi
	update_one "${id}" "${name}" "${old_image_id}" "${old_created}"
done < <(echo "${targets}" | jq -c '.[]')

echo "All updated Unraid containers are RUNNING:"
echo "${confirmed}" | jq -r '.[] | "- \(.names | join(", ")) state=\(.state // "unknown") image=\(.image) imageId=\(.imageId // "unknown")"'
