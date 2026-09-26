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

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

trim_trailing_slash() {
    printf '%s' "${1%/}"
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
    require_command npm
    require_command corepack

    current_version="$(node -v | sed 's/^v//')"
    if [[ "${current_version}" != "${NODE_VERSION}" && "${current_version}" != "${NODE_VERSION}".* ]]; then
        log "Installing Node.js ${NODE_VERSION}"
        n "${NODE_VERSION}"
        hash -r
    fi

    log "Activating pnpm ${PNPM_VERSION}"
    corepack enable
    corepack prepare "pnpm@${PNPM_VERSION}" --activate
}

cleanup() {
    local remove_token

    if [[ ! -d "${RUNNER_HOME}" ]]; then
        return
    fi

    if [[ ! -f "${RUNNER_HOME}/.runner" ]]; then
        return
    fi

    if remove_token="$(fetch_remove_token 2>/dev/null)"; then
        log "Removing runner registration"
        gosu runner bash -lc "cd '${RUNNER_HOME}' && ./config.sh remove --token '${remove_token}'" || true
        return
    fi

    log "Skipping deregistration because no PAT/token is available for a remove token"
}

handle_signal() {
    if [[ -n "${runner_pid:-}" ]]; then
        kill "${runner_pid}" 2>/dev/null || true
    fi
}

main() {
    local -a config_args

    require_command curl
    require_command jq
    require_command gosu

    : "${GITHUB_URL:?Set GITHUB_URL to a repository, organization, or enterprise URL.}"

    configure_node_toolchain

    mkdir -p "${RUNNER_HOME}"
    chown -R runner:runner "${RUNNER_HOME}"

    cd "${RUNNER_HOME}"

    trap cleanup EXIT INT TERM
    trap handle_signal INT TERM

    if [[ -f "${RUNNER_HOME}/.runner" ]]; then
        log "Existing runner configuration detected; skipping registration"
    else
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
    fi

    log "Starting runner"
    gosu runner ./run.sh &
    runner_pid=$!
    wait "${runner_pid}"
}

main "$@"
