#!/usr/bin/env bash
# ============================================================================
# scripts/lib/iics.sh - thin client for the IICS REST API (v2).
#   iics_login                 -> sets IICS_SESSION_ID, IICS_SERVER_URL
#   iics_run_task <name> [MTT] -> starts a task, waits; sets IICS_LAST_ROWS_OK,
#                                 IICS_LAST_ROWS_FAILED, IICS_LAST_RUN_ID
#   iics_logout
#   iics_render_param_file     -> writes the per-run parameter file
# Source after common.sh.
# ============================================================================

# IICS_LAST_* are read by the sourcing script (run_aml_batch.sh)
# shellcheck disable=SC2034
[[ -n "${_AML_IICS_LOADED:-}" ]] && return 0
_AML_IICS_LOADED=1

IICS_SESSION_ID=""
IICS_SERVER_URL=""
IICS_LAST_ROWS_OK=0
IICS_LAST_ROWS_FAILED=0
IICS_LAST_RUN_ID=""

_iics_curl() {
  # --fail-with-body keeps the API error JSON for the log
  curl --silent --show-error --fail-with-body --max-time 60 \
       -H "Content-Type: application/json" -H "Accept: application/json" "$@"
}

iics_login() {
  require_cmd curl jq
  [[ -n "${IICS_USERNAME:-}" && -n "${IICS_PASSWORD:-}" ]] \
    || die "IICS_USERNAME / IICS_PASSWORD are not set (run with AML_RUN_MODE=LOCAL to skip IICS)"

  local body resp
  body="$(jq -n --arg u "${IICS_USERNAME}" --arg p "${IICS_PASSWORD}" \
          '{"@type":"login", username:$u, password:$p}')"
  resp="$(_iics_curl -X POST "${IICS_LOGIN_URL}" --data @- <<<"${body}")" \
    || die "IICS login failed: ${resp:-no response}"

  IICS_SESSION_ID="$(jq -r '.icSessionId // empty' <<<"${resp}")"
  IICS_SERVER_URL="$(jq -r '.serverUrl // empty' <<<"${resp}")"
  [[ -n "${IICS_SESSION_ID}" && -n "${IICS_SERVER_URL}" ]] || die "IICS login returned no session: ${resp}"
  log_info "IICS login OK (pod ${IICS_SERVER_URL%%/saas*})"
}

iics_logout() {
  [[ -z "${IICS_SESSION_ID}" ]] && return 0
  _iics_curl -X POST "${IICS_SERVER_URL}/api/v2/user/logout" -H "icSessionId: ${IICS_SESSION_ID}" >/dev/null 2>&1 || true
  IICS_SESSION_ID=""
}

# Re-login transparently if the 30-minute idle session expired during a long run
_iics_ensure_session() {
  if [[ -z "${IICS_SESSION_ID}" ]]; then
    iics_login
    return
  fi
  if ! _iics_curl "${IICS_SERVER_URL}/api/v2/user/${IICS_USERNAME}" -H "icSessionId: ${IICS_SESSION_ID}" >/dev/null 2>&1; then
    log_info "IICS session expired, logging in again"
    IICS_SESSION_ID=""
    iics_login
  fi
}

# iics_run_task <task_name> [task_type]
# Call directly (not in $(...)) so the session survives. Returns 1 on failure/timeout.
iics_run_task() {
  local task_name="$1" task_type="${2:-MTT}"
  local resp run_id task_id elapsed=0 state log_entry

  _iics_ensure_session

  resp="$(_iics_curl -X POST "${IICS_SERVER_URL}/api/v2/job" -H "icSessionId: ${IICS_SESSION_ID}" \
          --data "$(jq -n --arg n "${task_name}" --arg t "${task_type}" '{"@type":"job", taskName:$n, taskType:$t}')")" \
    || { log_error "Could not start IICS task ${task_name}: ${resp:-no response}"; return 1; }

  run_id="$(jq -r '.runId // empty' <<<"${resp}")"
  IICS_LAST_RUN_ID="${run_id}"
  task_id="$(jq -r '.taskId // empty' <<<"${resp}")"
  [[ -n "${run_id}" ]] || { log_error "IICS did not return a runId for ${task_name}: ${resp}"; return 1; }
  log_info "Started IICS ${task_type} ${task_name} (taskId=${task_id}, runId=${run_id})"

  # Poll the activity log; an entry appears only once the run has finished
  while (( elapsed < IICS_TASK_TIMEOUT_SECONDS )); do
    sleep "${IICS_POLL_SECONDS}"
    elapsed=$(( elapsed + IICS_POLL_SECONDS ))
    _iics_ensure_session

    log_entry="$(_iics_curl "${IICS_SERVER_URL}/api/v2/activity/activityLog?taskId=${task_id}&runId=${run_id}" \
                 -H "icSessionId: ${IICS_SESSION_ID}" 2>/dev/null | jq -c '.[0] // empty')" || log_entry=""

    if [[ -z "${log_entry}" ]]; then
      (( elapsed % 300 == 0 )) && log_info "  ${task_name} still running (${elapsed}s)"
      continue
    fi

    # state: 1 = success, 2 = success with warnings, 3 = failed
    state="$(jq -r '.state' <<<"${log_entry}")"
    local ok failed err
    ok="$(jq -r '.successTargetRows // 0' <<<"${log_entry}")"
    failed="$(jq -r '.failedTargetRows // 0' <<<"${log_entry}")"
    err="$(jq -r '.errorMsg // ""' <<<"${log_entry}")"

    case "${state}" in
      1) log_info "IICS ${task_name} succeeded: ${ok} rows written, ${failed} rejected" ;;
      2) log_warn "IICS ${task_name} finished with warnings: ${ok} rows written, ${failed} rejected. ${err}" ;;
      *) log_error "IICS ${task_name} FAILED (state=${state}): ${err}"; return 1 ;;
    esac
    IICS_LAST_ROWS_OK="${ok}"
    IICS_LAST_ROWS_FAILED="${failed}"
    return 0
  done

  log_error "IICS ${task_name} did not finish within ${IICS_TASK_TIMEOUT_SECONDS}s (runId=${run_id})"
  return 1
}

# Renders informatica/iics_orchestration/aml_nightly.param.template for this run
iics_render_param_file() {
  local batch_id="$1" business_date="$2"
  local template="${AML_HOME}/informatica/iics_orchestration/aml_nightly.param.template"
  local out_dir="${IICS_PARAM_DIR:-${AML_RUN_DIR}}"
  local out="${out_dir}/aml_nightly.param"

  mkdir -p "${out_dir}"
  sed -e "s|\${BATCH_ID}|${batch_id}|g" \
      -e "s|\${BUSINESS_DATE}|${business_date}|g" \
      -e "s|\${AML_INBOUND_DIR}|${AML_INBOUND_DIR}|g" \
      -e "s|\${AML_OUTBOUND_DIR}|${AML_OUTBOUND_DIR}|g" \
      -e "s|\${AML_HOME}|${AML_HOME}|g" \
      "${template}" > "${out}.tmp"
  mv "${out}.tmp" "${out}"
  log_info "Rendered IICS parameter file ${out}"
}
