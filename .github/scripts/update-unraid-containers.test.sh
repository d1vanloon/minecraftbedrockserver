#!/bin/bash
# Exercises update-unraid-containers.sh against a fake curl.
# The fake Unraid API covers a gateway timeout that finishes in the
# background, a timeout that does not apply the new image, and a direct 200.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${root}/update-unraid-containers.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin"

cat > "${work}/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

output=""
data=""
args=("$@")
i=0
while [[ "${i}" -lt "${#args[@]}" ]]; do
	arg="${args[$i]}"
	case "${arg}" in
		-o)
			output="${args[$((i + 1))]}"
			i=$((i + 2))
			;;
		--data)
			data="${args[$((i + 1))]}"
			i=$((i + 2))
			;;
		--data=*)
			data="${arg#--data=}"
			i=$((i + 1))
			;;
		*)
			i=$((i + 1))
			;;
	esac
done

if [[ -z "${data}" || -z "${output}" ]]; then
	echo "fake curl: expected --data and -o" >&2
	exit 2
fi
if [[ -z "${FAKE_UNRAID_CALLS:-}" || -z "${FAKE_UNRAID_SCENARIO:-}" ]]; then
	echo "fake curl: FAKE_UNRAID_CALLS and FAKE_UNRAID_SCENARIO are required" >&2
	exit 2
fi

if echo "${data}" | jq -e '.query | contains("updateContainers")' >/dev/null; then
	echo "fake curl: bulk updateContainers was sent" >&2
	exit 99
fi
if echo "${data}" | jq -e '.variables | has("ids")' >/dev/null; then
	echo "fake curl: bulk ids variable was sent" >&2
	exit 99
fi

kind="other"
if echo "${data}" | jq -e '.query | contains("updateContainer(")' >/dev/null; then
	kind="mutation"
elif echo "${data}" | jq -e '.query | contains("GetContainers")' >/dev/null; then
	kind="query"
fi

jq -nc \
	--arg kind "${kind}" \
	--argjson variables "$(echo "${data}" | jq '.variables')" \
	'{kind: $kind, variables: $variables}' >> "${FAKE_UNRAID_CALLS}"

mutation_count="$(jq -s '[.[] | select(.kind == "mutation")] | length' "${FAKE_UNRAID_CALLS}")"
requested_id="$(echo "${data}" | jq -r '.variables.id // empty')"

write_response() {
	local code="$1"
	local body="$2"
	printf '%s' "${body}" > "${output}"
	printf '%s' "${code}"
}

fam_list() {
	local image_id="$1"
	local created="$2"
	local state="$3"
	jq -n \
		--arg imageId "${image_id}" \
		--argjson created "${created}" \
		--arg state "${state}" \
		'{data:{docker:{containers:[{
			id:"docker:fam",
			names:["/fam-minecraft"],
			image:"ghcr.io/d1vanloon/minecraftbedrockserver",
			imageId:$imageId,
			created:$created,
			state:$state
		}]}}}'
}

full_list() {
	jq -n '{data:{docker:{containers:[
		{id:"docker:fam",names:["/fam-minecraft"],image:"ghcr.io/d1vanloon/minecraftbedrockserver",imageId:"sha256:old",created:100,state:"RUNNING"},
		{id:"docker:binhex",names:["/binhex-minecraftbedrockserver"],image:"ghcr.io/d1vanloon/minecraftbedrockserver",imageId:"sha256:old-binhex",created:110,state:"RUNNING"},
		{id:"docker:stopped",names:["/stopped-minecraft"],image:"ghcr.io/d1vanloon/minecraftbedrockserver",imageId:"sha256:old-stopped",created:90,state:"EXITED"}
	]}}}'
}

update_body() {
	local id="$1"
	local name="$2"
	local image_id="$3"
	jq -n \
		--arg id "${id}" \
		--arg name "${name}" \
		--arg imageId "${image_id}" \
		'{data:{docker:{updateContainer:{
			id:$id,
			names:[$name],
			state:"RUNNING",
			image:"ghcr.io/d1vanloon/minecraftbedrockserver",
			imageId:$imageId,
			created:200
		}}}}'
}

nginx_504='<html>
<head><title>504 Gateway Time-out</title></head>
<body>
<center><h1>504 Gateway Time-out</h1></center>
<hr><center>nginx</center>
</body>
</html>'

case "${FAKE_UNRAID_SCENARIO}" in
	gateway_then_new_image|curl_timeout_then_new_image|created_changed)
		if [[ "${kind}" == "query" ]]; then
			if [[ "${mutation_count}" -ge 1 ]]; then
				if [[ "${FAKE_UNRAID_SCENARIO}" == "created_changed" ]]; then
					write_response 200 "$(fam_list "sha256:old" 200 RUNNING)"
				else
					write_response 200 "$(fam_list "sha256:new" 200 RUNNING)"
				fi
			else
				write_response 200 "$(fam_list "sha256:old" 100 RUNNING)"
			fi
		elif [[ "${kind}" == "mutation" ]]; then
			if [[ "${mutation_count}" -ne 1 ]]; then
				echo "fake curl: unexpected mutation ${mutation_count} in ${FAKE_UNRAID_SCENARIO}" >&2
				exit 99
			fi
			if [[ "${FAKE_UNRAID_SCENARIO}" == "curl_timeout_then_new_image" ]]; then
				exit 28
			fi
			write_response 504 "${nginx_504}"
		else
			echo "fake curl: unexpected ${kind} request" >&2
			exit 99
		fi
		;;
	unchanged_then_retry)
		if [[ "${kind}" == "query" ]]; then
			write_response 200 "$(fam_list "sha256:old" 100 RUNNING)"
		elif [[ "${kind}" == "mutation" && "${mutation_count}" -eq 1 ]]; then
			write_response 504 "${nginx_504}"
		elif [[ "${kind}" == "mutation" && "${mutation_count}" -eq 2 ]]; then
			write_response 200 "$(update_body "docker:fam" "/fam-minecraft" "sha256:new")"
		else
			echo "fake curl: unexpected ${kind} request ${mutation_count} in unchanged_then_retry" >&2
			exit 99
		fi
		;;
	restarting_then_running)
		if [[ "${kind}" == "query" ]]; then
			queries_after="$(jq -s '
				[.[].kind] as $kinds
				| ([$kinds | to_entries[] | select(.value == "mutation")] | first.key) as $first
				| if $first == null then 0
				  else [$kinds[($first + 1):][] | select(. == "query")] | length
				  end
			' "${FAKE_UNRAID_CALLS}")"
			if [[ "${queries_after}" -eq 0 ]]; then
				write_response 200 "$(fam_list "sha256:old" 100 RUNNING)"
			elif [[ "${queries_after}" -eq 1 ]]; then
				write_response 200 "$(fam_list "sha256:new" 200 EXITED)"
			else
				write_response 200 "$(fam_list "sha256:new" 200 RUNNING)"
			fi
		elif [[ "${kind}" == "mutation" && "${mutation_count}" -eq 1 ]]; then
			write_response 504 "${nginx_504}"
		else
			echo "fake curl: unexpected ${kind} request in restarting_then_running" >&2
			exit 99
		fi
		;;
	two_containers)
		if [[ "${kind}" == "query" ]]; then
			write_response 200 "$(full_list)"
		elif [[ "${kind}" == "mutation" ]]; then
			case "${requested_id}" in
				docker:fam)
					write_response 200 "$(update_body "docker:fam" "/fam-minecraft" "sha256:new")"
					;;
				docker:binhex)
					write_response 200 "$(update_body "docker:binhex" "/binhex-minecraftbedrockserver" "sha256:new-binhex")"
					;;
				*)
					echo "fake curl: unexpected update id ${requested_id}" >&2
					exit 99
					;;
			esac
		else
			echo "fake curl: unexpected ${kind} request" >&2
			exit 99
		fi
		;;
	http_500)
		if [[ "${kind}" == "query" ]]; then
			write_response 200 "$(fam_list "sha256:old" 100 RUNNING)"
		elif [[ "${kind}" == "mutation" && "${mutation_count}" -eq 1 ]]; then
			write_response 500 "upstream failed"
		else
			echo "fake curl: unexpected ${kind} request in http_500" >&2
			exit 99
		fi
		;;
	*)
		echo "fake curl: unknown scenario ${FAKE_UNRAID_SCENARIO}" >&2
		exit 99
		;;
esac
EOF
chmod +x "${work}/bin/curl"

fail() {
	echo "FAIL: $*" >&2
	if [[ -n "${log_file:-}" && -f "${log_file}" ]]; then
		echo "----- script output -----" >&2
		cat "${log_file}" >&2
	fi
	if [[ -n "${calls_file:-}" && -f "${calls_file}" ]]; then
		echo "----- curl calls -----" >&2
		cat "${calls_file}" >&2
	fi
	exit 1
}

assert_log_contains() {
	local needle="$1"
	if ! grep -F -- "${needle}" "${log_file}" >/dev/null; then
		fail "expected log to contain: ${needle}"
	fi
}

assert_log_excludes() {
	local needle="$1"
	if grep -F -- "${needle}" "${log_file}" >/dev/null; then
		fail "expected log to omit: ${needle}"
	fi
}

run_case() {
	local scenario="$1"
	local expect_status="$2"
	local expect_mutations="$3"
	local poll_delay="${4:-0}"
	log_file="${work}/${scenario}.log"
	calls_file="${work}/${scenario}.calls"
	: > "${calls_file}"

	local status=0
	PATH="${work}/bin:${PATH}" \
		FAKE_UNRAID_CALLS="${calls_file}" \
		FAKE_UNRAID_SCENARIO="${scenario}" \
		UNRAID_API_URL="http://unraid.example" \
		UNRAID_API_KEY="test-key" \
		GATEWAY_GRACE="0" \
		POLL_DELAY="${poll_delay}" \
		CONFIRM_DELAY="0" \
		CONFIRM_ATTEMPTS="3" \
		UPDATE_TIMEOUT="30" \
		QUERY_TIMEOUT="5" \
		MAX_UPDATE_ATTEMPTS="3" \
		bash "${script}" > "${log_file}" 2>&1 || status=$?

	if [[ "${status}" -ne "${expect_status}" ]]; then
		fail "${scenario}: exit ${status}, expected ${expect_status}"
	fi

	local mutations
	mutations="$(jq -s '[.[] | select(.kind == "mutation")] | length' "${calls_file}")"
	if [[ "${mutations}" -ne "${expect_mutations}" ]]; then
		fail "${scenario}: ${mutations} mutation(s), expected ${expect_mutations}"
	fi

	if jq -se 'any(.[]; .kind != "query" and .kind != "mutation")' "${calls_file}" >/dev/null; then
		fail "${scenario}: unclassified curl call"
	fi

	echo "PASS ${scenario}"
}

run_case gateway_then_new_image 0 1
assert_log_contains "Gateway timed out updating fam-minecraft"
assert_log_contains "fam-minecraft is RUNNING with an updated image"
assert_log_contains "imageId=sha256:new"
assert_log_excludes "attempt 2/3"
assert_log_excludes "retrying update"

run_case unchanged_then_retry 0 2
assert_log_contains "Image id for fam-minecraft unchanged after 0s; retrying update"
assert_log_contains "attempt 2/3"
assert_log_contains "imageId=sha256:new"
assert_log_excludes "attempt 3/3"

run_case curl_timeout_then_new_image 0 1
assert_log_contains "Unraid API request failed (curl status 28)"
assert_log_contains "Gateway timed out updating fam-minecraft"
assert_log_contains "fam-minecraft is RUNNING with an updated image"
assert_log_excludes "attempt 2/3"

run_case created_changed 0 1
assert_log_contains "fam-minecraft is RUNNING with an updated image"
assert_log_excludes "attempt 2/3"

run_case restarting_then_running 0 1 0
assert_log_contains "Waiting for fam-minecraft to reach RUNNING (state=EXITED)"
assert_log_contains "fam-minecraft is RUNNING with an updated image"
assert_log_excludes "attempt 2/3"
assert_log_excludes "retrying update"

run_case two_containers 0 2
assert_log_contains "Skipping 1 stopped container(s)"
assert_log_contains "Updating fam-minecraft via Unraid API (attempt 1/3)"
assert_log_contains "Updating binhex-minecraftbedrockserver via Unraid API (attempt 1/3)"
assert_log_excludes "Updating stopped-minecraft"
assert_log_contains "imageId=sha256:new"
assert_log_contains "imageId=sha256:new-binhex"
ids="$(jq -sr '[.[] | select(.kind == "mutation") | .variables.id] | join(" ")' "${calls_file}")"
if [[ "${ids}" != "docker:fam docker:binhex" ]]; then
	fail "two_containers: mutation ids were '${ids}'"
fi

run_case http_500 1 1
assert_log_contains "Unraid API HTTP 500"
assert_log_contains "UpdateContainer failed for fam-minecraft"
assert_log_excludes "Gateway timed out"

echo "All update-unraid-containers tests passed"
