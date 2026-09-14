#!/usr/bin/env bash
# Recreate deployment with a single running application container and local rollback.
set -Eeuo pipefail

readonly APP_NAME="eureka-service"
readonly LEGACY_NAME="eureka-service"

PHASE="PREFLIGHT"
COMMITTED=false
OLD_STOPPED=false
PREVIOUS_ID=""
CANDIDATE_ID=""

log() { printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$PHASE" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
require_non_empty() { [[ -n "${!1:-}" ]] || fail "Required variable is missing: $1"; }
container_exists() { docker container inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1")" == "true" ]]; }
container_id() { docker inspect -f '{{.Id}}' "$1"; }

require_non_empty DEPLOY_ENV
require_non_empty IMAGE_REF
require_non_empty IMAGE_VERSION
require_non_empty DOCKER_NETWORK
require_non_empty REMOTE_ENV_FILE

case "$DEPLOY_ENV" in dev|prod) ;; *) fail "DEPLOY_ENV must be dev or prod" ;; esac
[[ "$IMAGE_REF" != *' '* && "$IMAGE_VERSION" != *' '* ]] || fail "Image reference/version must not contain spaces"
[[ "$REMOTE_ENV_FILE" = /* ]] || fail "REMOTE_ENV_FILE must be an absolute path"

readonly ACTIVE_NAME="${APP_NAME}-${DEPLOY_ENV}-active"
readonly CANDIDATE_NAME="${APP_NAME}-${DEPLOY_ENV}-candidate"
readonly ROLLBACK_NAME="${APP_NAME}-${DEPLOY_ENV}-rollback"
readonly LOCK_FILE="/tmp/${APP_NAME}-${DEPLOY_ENV}.deploy.lock"
readonly LOG_DIRECTORY="${LOG_DIRECTORY:-/logs/eureka-service}"


exec 9>"$LOCK_FILE"
command -v flock >/dev/null 2>&1 || fail "flock is required on the deployment server"
flock -n 9 || fail "Another ${APP_NAME} deployment is already running for ${DEPLOY_ENV}"

read_env_var() {
    local key="$1" line value
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$REMOTE_ENV_FILE" | tail -n 1 || true)"
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    printf '%s' "$value"
}

health_probe() {
    docker run --rm --network "$DOCKER_NETWORK" "$HEALTHCHECK_IMAGE" \
        -fsS --connect-timeout 3 --max-time 5 \
        "http://${APP_NAME}:${SERVICE_PORT}${HEALTH_PATH}" >/dev/null
}

restart_count_is_zero() {
    local count
    count="$(docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null || true)"
    [[ "$count" =~ ^[0-9]+$ && "$count" == "0" ]]
}

candidate_healthy() {
    container_exists "$CANDIDATE_NAME" \
        && container_running "$CANDIDATE_NAME" \
        && restart_count_is_zero "$CANDIDATE_NAME" \
        && health_probe
}

eureka_probe() {
    local zone endpoint response
    zone="$(read_env_var DEFAULT_ZONE || true)"
    [[ -n "$zone" ]] || return 1
    zone="${zone%%,*}"
    endpoint="${zone%/}/apps/EUREKA-SERVICE/${EUREKA_INSTANCE_INSTANCE_ID}"
    response="$(docker run --rm --network "$DOCKER_NETWORK" "$HEALTHCHECK_IMAGE" \
        -fsS --connect-timeout 3 --max-time 5 -H 'Accept: application/json' "$endpoint" 2>/dev/null || true)"
    [[ "$response" == *'"status":"UP"'* || "$response" == *'"status" : "UP"'* ]]
}

wait_for_readiness() {
    local deadline consecutive=0
    deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        if candidate_healthy; then
            consecutive=$((consecutive + 1))
            log "Readiness probe passed (${consecutive}/3)"
            (( consecutive >= 3 )) && return 0
        else
            consecutive=0
            log "Waiting for candidate readiness"
        fi
        sleep 5
    done
    return 1
}

wait_for_eureka() {
    local deadline
    deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        eureka_probe && return 0
        log "Waiting for Eureka registration"
        sleep 5
    done
    return 1
}

show_candidate_evidence() {
    if container_exists "$CANDIDATE_NAME"; then
        docker inspect "$CANDIDATE_NAME" || true
        docker logs --tail 300 "$CANDIDATE_NAME" || true
    fi
}

remove_candidate() {
    container_exists "$CANDIDATE_NAME" || return 0
    docker rm -f "$CANDIDATE_NAME" || true
}

remove_candidate_image_if_unused() {
    local candidate_image active_image rollback_image
    candidate_image="$(docker image inspect -f '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)"
    [[ -n "$candidate_image" ]] || return 0
    active_image="$(docker inspect -f '{{.Image}}' "$ACTIVE_NAME" 2>/dev/null || true)"
    rollback_image="$(docker inspect -f '{{.Image}}' "$ROLLBACK_NAME" 2>/dev/null || true)"
    [[ "$candidate_image" == "$active_image" || "$candidate_image" == "$rollback_image" ]] || docker image rm "$candidate_image" || true
}

remove_replaced_rollback() {
    local old_rollback_image active_image candidate_image
    old_rollback_image="$(docker inspect -f '{{.Image}}' "$ROLLBACK_NAME" 2>/dev/null || true)"
    docker rm "$ROLLBACK_NAME"
    [[ -n "$old_rollback_image" ]] || return 0
    active_image="$(docker inspect -f '{{.Image}}' "$ACTIVE_NAME" 2>/dev/null || true)"
    candidate_image="$(docker image inspect -f '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)"
    [[ "$old_rollback_image" == "$active_image" || "$old_rollback_image" == "$candidate_image" ]] || docker image rm "$old_rollback_image" || true
}

restore_previous() {
    [[ -n "$PREVIOUS_ID" ]] || return 0
    log "Restoring previous container ${PREVIOUS_ID}"
    remove_candidate
    if ! docker start "$PREVIOUS_ID"; then
        log "CRITICAL: previous container could not be started"
        return 1
    fi
    if container_exists "$ROLLBACK_NAME"; then
        docker rename "$ROLLBACK_NAME" "$ACTIVE_NAME"
    elif container_exists "$LEGACY_NAME"; then
        docker rename "$LEGACY_NAME" "$ACTIVE_NAME"
    fi
    container_exists "$ACTIVE_NAME" && container_running "$ACTIVE_NAME"
}

on_failure() {
    local status=$?
    trap - ERR EXIT INT TERM HUP
    if [[ "$COMMITTED" != true ]]; then
        log "Deployment failed with status ${status}; phase=${PHASE}"
        show_candidate_evidence
        if [[ "$OLD_STOPPED" == true ]]; then
            restore_previous || true
        else
            remove_candidate
        fi
        remove_candidate_image_if_unused
    fi
    exit "$status"
}
trap on_failure ERR EXIT INT TERM HUP

PHASE="PREFLIGHT"
docker info >/dev/null
[[ -f "$REMOTE_ENV_FILE" && -r "$REMOTE_ENV_FILE" ]] || fail "Remote env file is missing or unreadable"
docker network inspect "$DOCKER_NETWORK" >/dev/null
mkdir -p "$LOG_DIRECTORY"
docker pull "$IMAGE_REF" >/dev/null

# Reconcile a container left by the old Jenkinsfile once, without changing its image.
if ! container_exists "$ACTIVE_NAME" && ! container_exists "$CANDIDATE_NAME" && container_exists "$LEGACY_NAME"; then
    container_running "$LEGACY_NAME" || fail "Legacy container is stopped; resolve it manually before deployment"
    docker rename "$LEGACY_NAME" "$ACTIVE_NAME"
fi

if container_exists "$CANDIDATE_NAME"; then
    log "Found stale candidate from an interrupted deployment"
    if ! container_exists "$ACTIVE_NAME" && container_exists "$ROLLBACK_NAME"; then
        remove_candidate
        docker start "$ROLLBACK_NAME"
        docker rename "$ROLLBACK_NAME" "$ACTIVE_NAME"
    else
        remove_candidate
    fi
fi

if ! container_exists "$ACTIVE_NAME" && container_exists "$ROLLBACK_NAME" && container_running "$ROLLBACK_NAME"; then
    docker rename "$ROLLBACK_NAME" "$ACTIVE_NAME"
fi

if container_exists "$ACTIVE_NAME" && ! container_running "$ACTIVE_NAME"; then
    fail "Active container is stopped; resolve the incident manually before deployment"
fi

if container_exists "$ROLLBACK_NAME" && container_running "$ROLLBACK_NAME"; then
    fail "Rollback container is unexpectedly running"
fi

if container_exists "$ACTIVE_NAME"; then
    PREVIOUS_ID="$(container_id "$ACTIVE_NAME")"
    if container_exists "$ROLLBACK_NAME"; then
        remove_replaced_rollback
    fi
    PHASE="OLD_STOPPED"
    docker stop --time 30 "$ACTIVE_NAME"
    OLD_STOPPED=true
    docker rename "$ACTIVE_NAME" "$ROLLBACK_NAME"
else
    log "First deployment: no previous container is available for rollback"
fi

PHASE="CANDIDATE_STARTED"
EUREKA_INSTANCE_INSTANCE_ID="${APP_NAME}-${DEPLOY_ENV}-${IMAGE_VERSION}"
export EUREKA_INSTANCE_INSTANCE_ID
CANDIDATE_ID="$(docker run -d \
    --name "$CANDIDATE_NAME" \
    --env-file "$REMOTE_ENV_FILE" \
    --env EUREKA_INSTANCE_INSTANCE_ID="$EUREKA_INSTANCE_INSTANCE_ID" \
    --network "$DOCKER_NETWORK" \
    --network-alias "$APP_NAME" \
    --volume "${LOG_DIRECTORY}:/app/logs" \
    --restart unless-stopped \
    --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
    --label app="$APP_NAME" \
    --label environment="$DEPLOY_ENV" \
    --label version="$IMAGE_VERSION" \
    --label jenkins-build="${JENKINS_BUILD_NUMBER:-unknown}" \
    --label role=candidate \
    "$IMAGE_REF")"
log "Candidate started: ${CANDIDATE_ID}"

PHASE="DEPLOY_COMMITTED"
docker rename "$CANDIDATE_NAME" "$ACTIVE_NAME"
COMMITTED=true
log "Deployment committed after container start: environment=${DEPLOY_ENV} image=${IMAGE_REF} active=$(container_id "$ACTIVE_NAME")"
