#!/usr/bin/env bash
# ============================================================================
# archive_files.sh - move processed inbound files to a dated, compressed
# archive and purge archives/logs past retention.
#
#   archive_files.sh <YYYYMMDD>
# ============================================================================
AML_SCRIPT_NAME="archive_files"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUSINESS_DATE="${1:?usage: $0 YYYYMMDD}"
[[ "${BUSINESS_DATE}" =~ ^[0-9]{8}$ ]] || die "Invalid date ${BUSINESS_DATE}" 2

dest="${AML_ARCHIVE_DIR}/${BUSINESS_DATE:0:4}/${BUSINESS_DATE}"
mkdir -p "${dest}"

moved=0
shopt -s nullglob
for f in "${AML_INBOUND_DIR}"/*_"${BUSINESS_DATE}".dat "${AML_INBOUND_DIR}"/*_"${BUSINESS_DATE}".dat.ctl \
         "${AML_INBOUND_DIR}"/injected_patterns_"${BUSINESS_DATE}".csv; do
  [[ -f "${f}" ]] || continue
  gzip -c "${f}" > "${dest}/$(basename "${f}").gz"
  # verify before deleting the original
  gzip -t "${dest}/$(basename "${f}").gz" || die "Archive verification failed for ${f}"
  rm -f "${f}"
  moved=$(( moved + 1 ))
done
shopt -u nullglob
log_info "Archived ${moved} file(s) to ${dest}"

purged="$(find "${AML_ARCHIVE_DIR}" -type f -name '*.gz' -mtime +"${AML_ARCHIVE_RETENTION_DAYS:-90}" -print -delete | wc -l)"
find "${AML_ARCHIVE_DIR}" -mindepth 1 -type d -empty -delete
logs="$(find "${AML_LOG_DIR}" -type f -name '*.log' -mtime +"${AML_LOG_RETENTION_DAYS:-30}" -print -delete | wc -l)"
find "${AML_RUN_DIR}" -maxdepth 1 -type d -name 'sqlldr_*' -mtime +7 -exec rm -rf {} +

log_info "Retention: purged ${purged} archive file(s) and ${logs} log file(s)"
