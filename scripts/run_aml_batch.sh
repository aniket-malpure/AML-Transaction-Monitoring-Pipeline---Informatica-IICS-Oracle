#!/usr/bin/env bash
# ============================================================================
# run_aml_batch.sh - nightly AML transaction monitoring orchestrator
#
#   run_aml_batch.sh [-d YYYYMMDD] [-m IICS|LOCAL] [-f] [-s STEP] [-l]
#
#     -d  business date to process (default: yesterday)
#     -m  run mode: IICS (mapping tasks via REST API) or LOCAL (SQL*Loader)
#     -f  force a full reprocess of a date that already SUCCEEDED
#     -s  run only this step (e.g. -s RUN_AML_RULES), honouring restart state
#     -l  list the steps and exit
#
# Restart behaviour: every step is recorded in ETL_STEP_LOG. If last night's
# batch failed at step 12, running this script again for the same date reuses
# the batch id and starts at step 12; steps 1-11 are skipped. All steps are
# idempotent, so a forced rerun is safe too, but the default is to redo only
# what failed instead of the whole chain.
#
# Exit codes: 0 success, 1 step failed, 2 usage, 3 another run in progress
# ============================================================================
AML_SCRIPT_NAME="run_aml_batch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/iics.sh
source "${SCRIPT_DIR}/lib/iics.sh"

# ------------------------------------------------------------------ steps
# seq | step name | type | IICS task (IICS mode) | local action
# type: FILE_CHECK, IICS_TASK (SQL*Loader in LOCAL mode), PLSQL, SHELL
STEPS=(
  "10|CHECK_INBOUND_FILES|FILE_CHECK|-|check_files"
  "20|STAGE_CUSTOMERS|IICS_TASK|mt_STG_CUSTOMER_LOAD|stg_customer:customers"
  "21|STAGE_ACCOUNTS|IICS_TASK|mt_STG_ACCOUNT_LOAD|stg_account:accounts"
  "22|STAGE_TRANSACTIONS|IICS_TASK|mt_STG_TRANSACTION_LOAD|stg_transaction:transactions"
  "23|STAGE_SANCTIONS|IICS_TASK|mt_STG_SANCTIONS_LOAD|stg_sanctions:sanctions_list"
  "24|STAGE_COUNTRY_RISK|IICS_TASK|mt_STG_COUNTRY_RISK_LOAD|stg_country_risk:country_risk"
  "30|VALIDATE_STAGING|PLSQL|-|pkg_load_dw.validate_staging"
  "40|LOAD_DIM_COUNTRY|PLSQL|-|pkg_load_dw.load_dim_country"
  "41|LOAD_DIM_SANCTIONED_PARTY|PLSQL|-|pkg_load_dw.load_dim_sanctioned_party"
  "42|LOAD_DIM_CUSTOMER|PLSQL|-|pkg_load_dw.load_dim_customer"
  "43|LOAD_DIM_ACCOUNT|PLSQL|-|pkg_load_dw.load_dim_account"
  "50|LOAD_FACT_TRANSACTION|PLSQL|-|pkg_load_dw.load_fact_transaction"
  "51|GATHER_STATS|PLSQL|-|pkg_load_dw.gather_stats"
  "60|RUN_AML_RULES|PLSQL|-|pkg_aml_rules.run_all"
  "70|EXTRACT_ALERTS|IICS_TASK|mt_OUT_AML_ALERT_EXTRACT|extract_alerts"
  "80|ARCHIVE_INBOUND|SHELL|-|archive_inbound"
)

usage() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

BUSINESS_DATE="$(date -d 'yesterday' +%Y%m%d)"
RUN_MODE="${AML_RUN_MODE:-LOCAL}"
FORCE="N"
ONLY_STEP=""

while getopts ":d:m:fs:lh" opt; do
  case "${opt}" in
    d) BUSINESS_DATE="${OPTARG}" ;;
    m) RUN_MODE="${OPTARG^^}" ;;
    f) FORCE="Y" ;;
    s) ONLY_STEP="${OPTARG^^}" ;;
    l) printf '%s\n' "${STEPS[@]}" | awk -F'|' '{printf "%-4s %-28s %-11s %s\n",$1,$2,$3,$4}'; exit 0 ;;
    h|*) usage ;;
  esac
done

[[ "${BUSINESS_DATE}" =~ ^[0-9]{8}$ ]] && date -d "${BUSINESS_DATE}" >/dev/null 2>&1 \
  || die "Invalid business date '${BUSINESS_DATE}' (expected YYYYMMDD)" 2
[[ "${RUN_MODE}" == "IICS" || "${RUN_MODE}" == "LOCAL" ]] || die "Run mode must be IICS or LOCAL" 2
if [[ -n "${ONLY_STEP}" ]] && ! printf '%s\n' "${STEPS[@]}" | cut -d'|' -f2 | grep -qx "${ONLY_STEP}"; then
  die "Unknown step ${ONLY_STEP}. Use -l to list steps." 2
fi

require_cmd sqlplus flock
[[ "${RUN_MODE}" == "LOCAL" ]] && require_cmd sqlldr

AML_LOG_FILE="${AML_LOG_DIR}/aml_batch_${BUSINESS_DATE}.log"
mkdir -p "${AML_INBOUND_DIR}" "${AML_OUTBOUND_DIR}" "${AML_ARCHIVE_DIR}"

DATA_FILES=(customers accounts transactions sanctions_list country_risk)
BATCH_ID=""

# ======================================================================
# step implementations
# ======================================================================

# start_step / end_step wrap ETL_STEP_LOG so shell, IICS and SQL*Loader
# steps are recorded exactly like PL/SQL ones.
start_step() {   # seq name type -> echoes step_log_id
  sql_value "SELECT pkg_etl_control.start_step(${BATCH_ID}, $1, '$2', '$3') FROM dual;"
}

end_step() {     # step_log_id status read written rejected message
  local msg
  msg="$(sql_quote "${6:-}")"
  run_sql "EXEC pkg_etl_control.end_step($1, '$2', ${3:-NULL}, ${4:-NULL}, ${5:-NULL}, '${msg:0:3900}')" >/dev/null
}

check_files() {
  local f out line files=()
  for f in "${DATA_FILES[@]}"; do files+=("${AML_INBOUND_DIR}/${f}_${BUSINESS_DATE}.dat"); done

  out="$("${SCRIPT_DIR}/check_ctl_file.sh" "${files[@]}")" || return 1

  STEP_ROWS_READ=0
  while IFS='|' read -r name rows md5; do
    run_sql "EXEC pkg_etl_control.register_file(${BATCH_ID}, '${name}', ${rows}, '${md5}')" >/dev/null
    STEP_ROWS_READ=$(( STEP_ROWS_READ + rows ))
  done < <(grep -E '^[^ ]+\|[0-9]+\|[0-9a-f]{32}$' <<<"${out}")
  STEP_ROWS_WRITTEN=${STEP_ROWS_READ}
}

# LOCAL mode replacement for an IICS staging mapping task
sqlldr_load() {
  local table="$1" file_prefix="$2"
  local data_file="${AML_INBOUND_DIR}/${file_prefix}_${BUSINESS_DATE}.dat"
  local work="${AML_RUN_DIR}/sqlldr_${BATCH_ID}"
  local ctl="${work}/${table}.ctl" log="${work}/${table}.log" bad="${work}/${table}.bad"
  mkdir -p "${work}"

  sed -e "s|__BATCH_ID__|${BATCH_ID}|g" \
      -e "s|__DATA_FILE__|${data_file}|g" \
      -e "s|__FILE_NAME__|$(basename "${data_file}")|g" \
      "${AML_HOME}/sqlldr/${table}.ctl" > "${ctl}"

  # Credentials via parfile (mode 600) instead of the command line
  local parfile="${work}/${table}.par"
  ( umask 077
    if [[ "${AML_DB_USE_WALLET:-N}" == "Y" ]]; then
      echo "userid=/@${AML_DB_CONNECT}"
    else
      echo "userid=${AML_DB_USER}/\"${AML_DB_PASSWORD}\"@${AML_DB_CONNECT}"
    fi > "${parfile}" )

  local rc=0
  sqlldr parfile="${parfile}" control="${ctl}" log="${log}" bad="${bad}" silent=header,feedback || rc=$?
  rm -f "${parfile}"

  # sqlldr: 0 ok, 2 = warnings (some rows rejected), 1/3 = failure
  STEP_ROWS_WRITTEN="$(grep -Eo '^ *[0-9]+ Rows? successfully loaded' "${log}" | grep -Eo '[0-9]+' | head -1 || echo 0)"
  STEP_ROWS_REJECTED="$(grep -Eo '^ *[0-9]+ Rows? not loaded due to data errors' "${log}" | grep -Eo '[0-9]+' | head -1 || echo 0)"
  STEP_ROWS_READ=$(( ${STEP_ROWS_WRITTEN:-0} + ${STEP_ROWS_REJECTED:-0} ))

  case "${rc}" in
    0) log_info "SQL*Loader ${table}: ${STEP_ROWS_WRITTEN} rows loaded" ;;
    2) log_warn "SQL*Loader ${table}: ${STEP_ROWS_WRITTEN} loaded, ${STEP_ROWS_REJECTED} rejected (see ${bad})" ;;
    *) log_error "SQL*Loader ${table} failed rc=${rc}; see ${log}"; return 1 ;;
  esac
}

iics_task() {
  local task="$1"
  iics_run_task "${task}" MTT || return 1
  STEP_ROWS_WRITTEN="${IICS_LAST_ROWS_OK}"
  STEP_ROWS_REJECTED="${IICS_LAST_ROWS_FAILED}"
  STEP_IICS_RUN_ID="${IICS_LAST_RUN_ID}"
}

# PL/SQL steps log themselves in the same session, so the row counters the
# package sets (pkg_etl_control.g_rows_*) are recorded with the step.
plsql_step() {
  local seq="$1" name="$2" proc="$3"
  run_sql "
DECLARE
  l_step NUMBER;
BEGIN
  l_step := pkg_etl_control.start_step(${BATCH_ID}, ${seq}, '${name}', 'PLSQL');
  BEGIN
    ${proc}(${BATCH_ID});
    pkg_etl_control.end_step(l_step, 'SUCCEEDED');
  EXCEPTION
    WHEN OTHERS THEN
      pkg_aml_util.log_error(${BATCH_ID}, '${name}');
      pkg_etl_control.end_step(l_step, 'FAILED', p_message => SUBSTR(SQLERRM, 1, 3900));
      RAISE;
  END;
END;
/"
}

extract_alerts() {
  local out="${AML_OUTBOUND_DIR}/aml_alerts_${BUSINESS_DATE}.csv"
  run_sql "
SET MARKUP CSV ON QUOTE ON
SET HEADING ON PAGESIZE 50000 EMBEDDED ON
SPOOL ${out}.tmp
SELECT alert_id, case_id, rule_code, severity, risk_score, window_start_date, window_end_date,
       account_id, customer_id, customer_name, txn_count, total_amount, alert_reason, match_detail, created_ts
  FROM v_alert_extract
 WHERE batch_id = ${BATCH_ID}
 ORDER BY risk_score DESC, alert_id;
SPOOL OFF" >/dev/null
  mv "${out}.tmp" "${out}"
  STEP_ROWS_WRITTEN=$(( $(grep -c . "${out}") - 1 ))
  (( STEP_ROWS_WRITTEN < 0 )) && STEP_ROWS_WRITTEN=0
  printf 'FILE=%s\nROWS=%s\nMD5=%s\n' "$(basename "${out}")" "${STEP_ROWS_WRITTEN}" \
         "$(md5sum "${out}" | awk '{print $1}')" > "${out}.ctl"
  log_info "Wrote ${STEP_ROWS_WRITTEN} alert(s) to ${out}"
}

archive_inbound() {
  "${SCRIPT_DIR}/archive_files.sh" "${BUSINESS_DATE}"
}

# ======================================================================
# step runner
# ======================================================================
run_step() {
  local seq="$1" name="$2" type="$3" iics_task_name="$4" action="$5"
  local done_flag step_id attempts rc=0 started

  done_flag="$(sql_value "SELECT pkg_etl_control.step_succeeded(${BATCH_ID}, '${name}') FROM dual;")"
  if [[ "${done_flag}" == "Y" ]]; then
    log_info "[${seq}] ${name}: already SUCCEEDED in batch ${BATCH_ID}, skipping"
    return 0
  fi

  started=$(date +%s)
  log_info "[${seq}] ${name}: starting (${type})"

  if [[ "${type}" == "PLSQL" ]]; then
    retry "${AML_PLSQL_MAX_ATTEMPTS:-1}" "${AML_RETRY_BACKOFF_SECONDS:-60}" \
      plsql_step "${seq}" "${name}" "${action}" || rc=$?
  else
    STEP_ROWS_READ=""; STEP_ROWS_WRITTEN=""; STEP_ROWS_REJECTED=""; STEP_IICS_RUN_ID=""
    step_id="$(start_step "${seq}" "${name}" "${type}")"
    attempts="${AML_STEP_MAX_ATTEMPTS:-3}"

    case "${type}" in
      FILE_CHECK) retry 1 0 check_files || rc=$? ;;
      SHELL)      retry 1 0 "${action}" || rc=$? ;;
      IICS_TASK)
        if [[ "${RUN_MODE}" == "IICS" ]]; then
          retry "${attempts}" "${AML_RETRY_BACKOFF_SECONDS:-60}" iics_task "${iics_task_name}" || rc=$?
        elif [[ "${action}" == *:* ]]; then
          retry "${attempts}" "${AML_RETRY_BACKOFF_SECONDS:-60}" sqlldr_load "${action%%:*}" "${action##*:}" || rc=$?
        else
          retry 1 0 "${action}" || rc=$?
        fi ;;
    esac

    if (( rc == 0 )); then
      end_step "${step_id}" SUCCEEDED "${STEP_ROWS_READ}" "${STEP_ROWS_WRITTEN}" "${STEP_ROWS_REJECTED}" \
               "${STEP_IICS_RUN_ID:+IICS runId ${STEP_IICS_RUN_ID}}"
    else
      end_step "${step_id}" FAILED "${STEP_ROWS_READ}" "${STEP_ROWS_WRITTEN}" "${STEP_ROWS_REJECTED}" \
               "rc=${rc}; see ${AML_LOG_FILE}"
    fi
  fi

  if (( rc != 0 )); then
    log_error "[${seq}] ${name}: FAILED after $(( $(date +%s) - started ))s (rc=${rc})"
    return "${rc}"
  fi
  log_info "[${seq}] ${name}: done in $(( $(date +%s) - started ))s"
}

# ======================================================================
# main
# ======================================================================
finish() {
  local rc=$?
  trap - EXIT
  if [[ -n "${BATCH_ID}" ]]; then
    if (( rc == 0 )); then
      run_sql "EXEC pkg_etl_control.end_batch(${BATCH_ID}, 'SUCCEEDED')" >/dev/null || true
      log_info "Batch ${BATCH_ID} (${BUSINESS_DATE}) SUCCEEDED"
    else
      run_sql "EXEC pkg_etl_control.end_batch(${BATCH_ID}, 'FAILED')" >/dev/null || true
      log_error "Batch ${BATCH_ID} (${BUSINESS_DATE}) FAILED. Rerun the same command to restart from the failed step."
      notify "[AML] nightly ${BUSINESS_DATE} FAILED (batch ${BATCH_ID})" \
             "Restart: ${SCRIPT_DIR}/run_aml_batch.sh -d ${BUSINESS_DATE} -m ${RUN_MODE}"
    fi
  fi
  [[ "${RUN_MODE}" == "IICS" ]] && iics_logout
  exit "${rc}"
}

main() {
  acquire_lock "aml_nightly"
  log_info "==== AML nightly: business date ${BUSINESS_DATE}, mode ${RUN_MODE}, force=${FORCE} ===="

  local bdate_sql="TO_DATE('${BUSINESS_DATE}','YYYYMMDD')"
  BATCH_ID="$(sql_value "SELECT pkg_etl_control.start_batch(${bdate_sql}, '${RUN_MODE}', p_force_rerun => '${FORCE}') FROM dual;")" \
    || die "Could not start batch for ${BUSINESS_DATE}"
  [[ "${BATCH_ID}" =~ ^[0-9]+$ ]] || die "start_batch returned '${BATCH_ID}'"
  trap finish EXIT

  local attempt
  attempt="$(sql_value "SELECT attempt_no FROM etl_batch_run WHERE batch_id = ${BATCH_ID};")"
  log_info "Batch ${BATCH_ID}, attempt ${attempt}"

  if [[ "${RUN_MODE}" == "IICS" ]]; then
    iics_login
    iics_render_param_file "${BATCH_ID}" "${BUSINESS_DATE}"
  fi

  local s seq name type task action
  for s in "${STEPS[@]}"; do
    IFS='|' read -r seq name type task action <<<"${s}"
    [[ -n "${ONLY_STEP}" && "${name}" != "${ONLY_STEP}" ]] && continue
    run_step "${seq}" "${name}" "${type}" "${task}" "${action}"
  done

  # Summary for the log / cron mail
  run_sql "
SET HEADING ON PAGESIZE 100 LINESIZE 160
COLUMN step_name FORMAT A28
COLUMN rows_written FORMAT 999,999,999
SELECT step_seq, step_name, step_status, rows_read, rows_written, rows_rejected, elapsed_sec
  FROM v_etl_run_status WHERE batch_id = ${BATCH_ID} ORDER BY step_seq, step_name;
SELECT rule_code, COUNT(*) alerts FROM fact_aml_alert WHERE batch_id = ${BATCH_ID} GROUP BY rule_code ORDER BY 1;" \
    | tee -a "${AML_LOG_FILE}"

  # -s runs one step; the batch stays open until the full chain has passed
  if [[ -n "${ONLY_STEP}" ]]; then
    local pending
    pending="$(sql_value "SELECT COUNT(*) FROM (SELECT DISTINCT step_name FROM etl_step_log WHERE batch_id = ${BATCH_ID} AND status = 'SUCCEEDED');")"
    if (( pending < ${#STEPS[@]} )); then
      log_info "Single step ${ONLY_STEP} done; ${pending}/${#STEPS[@]} steps complete, batch left FAILED for restart"
      trap - EXIT
      run_sql "EXEC pkg_etl_control.end_batch(${BATCH_ID}, 'FAILED')" >/dev/null
      exit 0
    fi
  fi
}

main "$@"
