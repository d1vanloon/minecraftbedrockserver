#!/bin/bash

if [[ -n "${HEALTHCHECK_COMMAND}" ]]; then
	eval "${HEALTHCHECK_COMMAND}"
	exit $?
fi

pgrep -f bedrock_server >/dev/null
