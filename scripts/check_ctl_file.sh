#!/usr/bin/env bash
# ============================================================================
# check_ctl_file.sh - validate an inbound data file against its .ctl trailer
#
#   check_ctl_file.sh <data_file> [<data_file> ...]
#
# Each <file>.dat must have <file>.dat.ctl containing ROWS=<n> and MD5=<hash>.
# Checks: file present and non-empty, row count (excluding header) matches,
# checksum matches, and the file is not still being written (size stable).
# Prints "<file>|<rows>|<md5>" for each valid file. Exit 0 only if all pass.
#
# Called by run_aml_batch.sh (FILE_CHECK step) and by the IICS command task
# cmd_validate_control_file converted from the PowerCenter workflow.
# ============================================================================
AML_SCRIPT_NAME="check_ctl_file"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

(( $# >= 1 )) || die "usage: $0 <data_file> [<data_file> ...]" 2
require_cmd md5sum wc stat

STABLE_WAIT_SECONDS="${STABLE_WAIT_SECONDS:-5}"
failures=0

for data_file in "$@"; do
  [[ "${data_file}" = /* ]] || data_file="${AML_INBOUND_DIR}/${data_file}"
  ctl_file="${data_file}.ctl"
  name="$(basename "${data_file}")"

  if [[ ! -s "${data_file}" ]]; then
    log_error "${name}: missing or empty"
    failures=$(( failures + 1 )); continue
  fi
  if [[ ! -f "${ctl_file}" ]]; then
    log_error "${name}: control file ${ctl_file##*/} not found (upstream transfer incomplete?)"
    failures=$(( failures + 1 )); continue
  fi

  # A file still growing means the SFTP drop has not finished
  size1="$(stat -c %s "${data_file}")"
  sleep "${STABLE_WAIT_SECONDS}"
  size2="$(stat -c %s "${data_file}")"
  if [[ "${size1}" != "${size2}" ]]; then
    log_error "${name}: still being written (${size1} -> ${size2} bytes)"
    failures=$(( failures + 1 )); continue
  fi

  expected_rows="$(grep -E '^ROWS=' "${ctl_file}" | cut -d= -f2 | tr -d '[:space:]')"
  expected_md5="$(grep -E '^MD5=' "${ctl_file}" | cut -d= -f2 | tr -d '[:space:]')"
  [[ "${expected_rows}" =~ ^[0-9]+$ ]] || { log_error "${name}: bad ROWS in control file"; failures=$(( failures + 1 )); continue; }

  actual_rows=$(( $(wc -l < "${data_file}") - 1 ))     # minus header
  actual_md5="$(md5sum "${data_file}" | awk '{print $1}')"

  if [[ "${actual_rows}" -ne "${expected_rows}" ]]; then
    log_error "${name}: row count ${actual_rows} != control ${expected_rows}"
    failures=$(( failures + 1 )); continue
  fi
  if [[ -n "${expected_md5}" && "${actual_md5}" != "${expected_md5}" ]]; then
    log_error "${name}: checksum mismatch (got ${actual_md5}, control ${expected_md5})"
    failures=$(( failures + 1 )); continue
  fi

  log_info "${name}: OK (${actual_rows} rows, md5 ${actual_md5})"
  echo "${name}|${actual_rows}|${actual_md5}"
done

(( failures == 0 )) || die "${failures} inbound file(s) failed validation" 1
