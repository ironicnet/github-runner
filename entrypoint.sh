#!/usr/bin/env bash

set -euo pipefail

readonly RUNNER_HOME="${RUNNER_HOME:-/home/runner/actions-runner}"
readonly RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
readonly RUNNER_NAME="${RUNNER_NAME:-$(hostname)-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
readonly RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux}"
readonly RUNNER_GROUP="${RUNNER_GROUP:-}"
readonly RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-false}"
readonly RUNNER_REPLACE="${RUNNER_REPLACE:-true}"
readonly RUNNER_DISABLE_UPDATE="${RUNNER_DISABLE_UPDATE:-false}"
readonly RUNNER_NO_DEFAULT_LABELS="${RUNNER_NO_DEFAULT_LABELS:-false}"
readonly NODE_VERSION="${NODE_VERSION:-22}"
readonly PNPM_VERSION="${PNPM_VERSION:-10.17.1}"
readonly RUNNER_STATE_FILE="${RUNNER_STATE_FILE:-${RUNNER_HOME}/.runner-config-state}"

registration_token=""

log() {
    printf '[runner] %s\n' "$*"
}

bool_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

node_version_matches() {
    local current_version="$1"
    local requested_version="$2"

    case "${requested_version}" in
        *.*)
            [[ "${current_version}" == "${requested_version}" || "${current_version}" == "${requested_version}".* ]]
            ;;
        *)
            [[ "${current_version%%.*}" == "${requested_version}" ]]
            ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

trim_trailing_slash() {
    printf '%s' "${1%/}"
}

desired_runner_state() {
    cat <<EOF
GITHUB_URL=${GITHUB_URL}
RUNNER_NAME=${RUNNER_NAME}
RUNNER_WORKDIR=${RUNNER_WORKDIR}
RUNNER_LABELS=${RUNNER_LABELS}
RUNNER_GROUP=${RUNNER_GROUP}
RUNNER_EPHEMERAL=${RUNNER_EPHEMERAL}
RUNNER_REPLACE=${RUNNER_REPLACE}
RUNNER_DISABLE_UPDATE=${RUNNER_DISABLE_UPDATE}
RUNNER_NO_DEFAULT_LABELS=${RUNNER_NO_DEFAULT_LABELS}
NODE_VERSION=${NODE_VERSION}
PNPM_VERSION=${PNPM_VERSION}
EOF
}

runner_config_is_current() {
    [[ -f "${RUNNER_STATE_FILE}" ]] && [[ "$(cat "${RUNNER_STATE_FILE}")" == "$(desired_runner_state)" ]]
}

persist_runner_state() {
    mkdir -p "$(dirname "${RUNNER_STATE_FILE}")" || return 1
    desired_runner_state > "${RUNNER_STATE_FILE}" || return 1
    chown runner:runner "${RUNNER_STATE_FILE}" || return 1
}

clear_local_runner_state() {
    rm -f \
        "${RUNNER_HOME}/.credentials" \
        "${RUNNER_HOME}/.credentials_rsaparams" \
        "${RUNNER_HOME}/.runner" \
        "${RUNNER_STATE_FILE}"
}

derive_api_base() {
    local url_no_scheme host

    if [[ -n "${GITHUB_API_URL:-}" ]]; then
        printf '%s' "$(trim_trailing_slash "${GITHUB_API_URL}")"
        return
    fi

    url_no_scheme="${GITHUB_URL#*://}"
    host="${url_no_scheme%%/*}"

    if [[ "${host}" == "github.com" ]]; then
        printf 'https://api.github.com'
    else
        printf 'https://%s/api/v3' "${host}"
    fi
}

parse_runner_target() {
    local raw_path
    local -a parts

    raw_path="${GITHUB_URL#*://}"
    raw_path="${raw_path#*/}"
    raw_path="${raw_path%%\?*}"
    raw_path="${raw_path%%\#*}"
    raw_path="$(trim_trailing_slash "${raw_path}")"
    IFS='/' read -r -a parts <<< "${raw_path}"

    if [[ "${#parts[@]}" -ge 2 && ( "${parts[0]}" == "orgs" || "${parts[0]}" == "organizations" ) ]]; then
        RUNNER_TARGET_KIND="org"
        RUNNER_TARGET_PATH="orgs/${parts[1]}"
        return
    fi

    if [[ "${#parts[@]}" -ge 2 && "${parts[0]}" == "enterprises" ]]; then
        RUNNER_TARGET_KIND="enterprise"
        RUNNER_TARGET_PATH="enterprises/${parts[1]}"
        return
    fi

    if [[ "${#parts[@]}" -ge 2 ]]; then
        RUNNER_TARGET_KIND="repo"
        RUNNER_TARGET_PATH="repos/${parts[0]}/${parts[1]}"
        return
    fi

    if [[ "${#parts[@]}" -eq 1 && -n "${parts[0]}" ]]; then
        RUNNER_TARGET_KIND="org"
        RUNNER_TARGET_PATH="orgs/${parts[0]}"
        return
    fi

    printf 'Unable to determine runner target from GITHUB_URL=%s\n' "${GITHUB_URL}" >&2
    exit 1
}

github_api_post() {
    local endpoint="$1"
    local token="$2"
    local auth_header
    local auth_prefix="Bearer"

    auth_header="Authorization: ${auth_prefix} ${token}"

    curl -fsSL -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "${auth_header}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$(derive_api_base)/${endpoint}"
}

fetch_registration_token() {
    if [[ -n "${RUNNER_TOKEN:-}" ]]; then
        printf '%s' "${RUNNER_TOKEN}"
        return
    fi

    if [[ -z "${GITHUB_PAT:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
        printf 'Set RUNNER_TOKEN or GITHUB_PAT/GITHUB_TOKEN.\n' >&2
        exit 1
    fi

    parse_runner_target
    github_api_post "${RUNNER_TARGET_PATH}/actions/runners/registration-token" "${GITHUB_PAT:-${GITHUB_TOKEN:-}}" | jq -er '.token'
}

fetch_remove_token() {
    if [[ -z "${GITHUB_PAT:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
        return 1
    fi

    parse_runner_target
    github_api_post "${RUNNER_TARGET_PATH}/actions/runners/remove-token" "${GITHUB_PAT:-${GITHUB_TOKEN:-}}" | jq -er '.token'
}

configure_node_toolchain() {
    local current_version

    require_command node

    current_version="$(node -v | sed 's/^v//')"
    if ! node_version_matches "${current_version}" "${NODE_VERSION}"; then
        log "Installing Node.js ${NODE_VERSION}"
        n "${NODE_VERSION}"
        hash -r
    fi

    require_command corepack

    log "Activating pnpm ${PNPM_VERSION}"
    corepack enable
    corepack prepare "pnpm@${PNPM_VERSION}" --activate
}

remove_existing_runner_config() {
    local remove_token

    if ! remove_token="$(fetch_remove_token 2>/dev/null)"; then
        printf 'Existing runner configuration does not match the requested environment. Set GITHUB_PAT or GITHUB_TOKEN so the runner can be reconfigured safely.\n' >&2
        exit 1
    fi

    log "Removing existing runner registration before reconfiguration"
    gosu runner bash -lc "cd '${RUNNER_HOME}' && ./config.sh remove --token '${remove_token}'"
    clear_local_runner_state
}

cleanup() {
    local remove_token

    if [[ ! -d "${RUNNER_HOME}" ]]; then
        return
    fi

    if [[ ! -f "${RUNNER_HOME}/.runner" ]]; then
        return
    fi

    if bool_true "${RUNNER_EPHEMERAL}"; then
        if remove_token="$(fetch_remove_token 2>/dev/null)"; then
            log "Removing ephemeral runner registration"
            gosu runner bash -lc "cd '${RUNNER_HOME}' && ./config.sh remove --token '${remove_token}'" || true
        else
            log "Skipping explicit deregistration for ephemeral runner because no PAT/token is available"
        fi
        clear_local_runner_state
        return
    fi

    if remove_token="$(fetch_remove_token 2>/dev/null)"; then
        log "Removing runner registration"
        gosu runner bash -lc "cd '${RUNNER_HOME}' && ./config.sh remove --token '${remove_token}'" || true
        clear_local_runner_state
        return
    fi

    log "Skipping deregistration because no PAT/token is available for a remove token"
}

handle_signal() {
    trap - EXIT

    if [[ -n "${runner_pid:-}" ]]; then
        kill -TERM -- "-${runner_pid}" 2>/dev/null || kill "${runner_pid}" 2>/dev/null || true
        wait "${runner_pid}" 2>/dev/null || true
    fi

    cleanup
    exit 0
}

main() {
    local -a config_args

    require_command curl
    require_command jq
    require_command gosu
    require_command setsid

    : "${GITHUB_URL:?Set GITHUB_URL to a repository, organization, or enterprise URL.}"

    configure_node_toolchain

    mkdir -p "${RUNNER_HOME}"
    chown -R runner:runner "${RUNNER_HOME}"

    cd "${RUNNER_HOME}"

    trap cleanup EXIT
    trap handle_signal INT TERM

    if [[ ! -f "${RUNNER_HOME}/.runner" ]] && { [[ -f "${RUNNER_HOME}/.credentials" ]] || [[ -f "${RUNNER_HOME}/.credentials_rsaparams" ]] || [[ -f "${RUNNER_STATE_FILE}" ]]; }; then
        log "Clearing incomplete local runner state"
        clear_local_runner_state
    fi

    if [[ -f "${RUNNER_HOME}/.runner" ]] && runner_config_is_current; then
        log "Existing runner configuration detected; skipping registration"
    else
        if [[ -f "${RUNNER_HOME}/.runner" ]]; then
            remove_existing_runner_config
        fi

        registration_token="$(fetch_registration_token)"

        config_args=(
            --url "${GITHUB_URL}"
            --token "${registration_token}"
            --name "${RUNNER_NAME}"
            --work "${RUNNER_WORKDIR}"
            --labels "${RUNNER_LABELS}"
            --unattended
        )

        if [[ -n "${RUNNER_GROUP}" ]]; then
            config_args+=(--runnergroup "${RUNNER_GROUP}")
        fi

        if bool_true "${RUNNER_EPHEMERAL}"; then
            config_args+=(--ephemeral)
        fi

        if bool_true "${RUNNER_REPLACE}"; then
            config_args+=(--replace)
        fi

        if bool_true "${RUNNER_DISABLE_UPDATE}"; then
            config_args+=(--disableupdate)
        fi

        if bool_true "${RUNNER_NO_DEFAULT_LABELS}"; then
            config_args+=(--no-default-labels)
        fi

        log "Configuring runner ${RUNNER_NAME} for ${GITHUB_URL}"
        gosu runner ./config.sh "${config_args[@]}"
        if ! persist_runner_state; then
            if remove_token="$(fetch_remove_token 2>/dev/null)"; then
                gosu runner bash -lc "cd '${RUNNER_HOME}' && ./config.sh remove --token '${remove_token}'" || true
            fi
            log "Failed to persist runner state; cleaning up local registration"
            clear_local_runner_state
            exit 1
        fi
    fi

    log "Starting runner"
    setsid gosu runner ./run.sh &
    runner_pid=$!
    wait "${runner_pid}"
}

main "$@"
