#!/usr/bin/env bash
# ============================================================================
# scripts/lib/common.sh - shared functions for every AML shell script.
# Source it; do not execute it.
# ============================================================================

[[ -n "${_AML_COMMON_LOADED:-}" ]] && return 0
_AML_COMMON_LOADED=1

set -o errexit -o nounset -o pipefail

AML_HOME="${AML_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export AML_HOME

_env_file="${AML_ENV_FILE:-${AML_HOME}/config/aml_pipeline.env}"
if [[ -f "${_env_file}" ]]; then
  # shellcheck source=/dev/null
  source "${_env_file}"
elif [[ -f "${AML_HOME}/config/aml_pipeline.env.example" ]]; then
  # shellcheck source=/dev/null
  source "${AML_HOME}/config/aml_pipeline.env.example"
fi

mkdir -p "${AML_LOG_DIR:=${AML_HOME}/logs}" "${AML_RUN_DIR:=${AML_HOME}/run}"

# ---------------------------------------------------------------- logging
AML_LOG_FILE="${AML_LOG_FILE:-${AML_LOG_DIR}/aml_$(date +%Y%m%d).log}"

_log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] [${AML_SCRIPT_NAME:-$(basename "$0")}:$$] $*"
  echo "${line}" >> "${AML_LOG_FILE}"
  if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
    echo "${line}" >&2
  else
    echo "${line}"
  fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

die() {
  local code="${2:-1}"
  log_error "$1"
  exit "${code}"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "Required command not found on PATH: ${c}"
  done
}

# ---------------------------------------------------------------- retry
# retry <max_attempts> <backoff_seconds> <command...>
# Backoff doubles each attempt (60, 120, 240 ...).
retry() {
  local max="$1" backoff="$2"; shift 2
  local attempt=1 rc=0
  while true; do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if (( attempt >= max )); then
      log_error "Giving up after ${attempt} attempt(s): $*"
      return "${rc}"
    fi
    log_warn "Attempt ${attempt}/${max} failed (rc=${rc}); retrying in ${backoff}s: $*"
    sleep "${backoff}"
    attempt=$(( attempt + 1 ))
    backoff=$(( backoff * 2 ))
  done
}

# ---------------------------------------------------------------- locking
# Prevents two nightly runs from overlapping (cron + manual rerun).
acquire_lock() {
  local name="$1"
  local lock_file="${AML_RUN_DIR}/${name}.lock"
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    die "Another ${name} run holds ${lock_file}" 3
  fi
  echo "$$" 1>&9
  log_info "Acquired lock ${lock_file}"
}

# ---------------------------------------------------------------- Oracle
# Credentials go through a here-doc, never the command line, so they do not
# show up in `ps` output. EXIT FAILURE (not SQL.SQLCODE): the shell only sees
# SQLCODE mod 256, so some ORA- errors would otherwise look like success.
_sqlplus_connect_line() {
  if [[ "${AML_DB_USE_WALLET:-N}" == "Y" ]]; then
    echo "connect /@${AML_DB_CONNECT}"
  else
    echo "connect ${AML_DB_USER}/\"${AML_DB_PASSWORD}\"@${AML_DB_CONNECT}"
  fi
}

# run_sql <sql text>   - runs a script, prints output, fails on any SQL error
run_sql() {
  local sql="$1"
  sqlplus -s -L /nolog <<EOF
WHENEVER OSERROR EXIT 9
WHENEVER SQLERROR EXIT FAILURE
$(_sqlplus_connect_line)
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET DEFINE OFF
SET LINESIZE 32767
SET TRIMOUT ON TRIMSPOOL ON
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
EXEC DBMS_SESSION.SET_IDENTIFIER('aml_batch');
${sql}
EXIT SUCCESS
EOF
}

# sql_value <query>   - prints the single value the query returns
sql_value() {
  local query="$1" out
  out="$(sqlplus -s -L /nolog <<EOF
WHENEVER OSERROR EXIT 9
WHENEVER SQLERROR EXIT FAILURE
$(_sqlplus_connect_line)
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF TAB OFF
SET DEFINE OFF
${query}
EXIT SUCCESS
EOF
)" || { echo "${out}" >&2; return 1; }
  echo "${out}" | sed -e '/^\s*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tail -n 1
}

# sql_quote <text> - escape a value for a single-quoted SQL literal
sql_quote() {
  printf "%s" "${1//\'/\'\'}"
}

# ---------------------------------------------------------------- notify
notify() {
  local subject="$1" body="${2:-}"
  if [[ "${AML_MAILER:-none}" == "none" ]] || ! command -v "${AML_MAILER}" >/dev/null 2>&1; then
    log_info "Notification (mailer disabled): ${subject}"
    return 0
  fi
  printf "%s\n\nLog: %s\n" "${body}" "${AML_LOG_FILE}" | "${AML_MAILER}" -s "${subject}" "${AML_ALERT_EMAIL}" \
    || log_warn "Notification failed: ${subject}"
}
