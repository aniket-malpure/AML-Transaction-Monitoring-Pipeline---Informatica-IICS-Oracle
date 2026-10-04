#!/usr/bin/env bash
# ============================================================================
# setup_db.sh - one-time database setup
#
#   setup_db.sh [--rebuild]
#
# 1. creates AML_OWNER (needs SYSTEM password in ORACLE_SYSTEM_PASSWORD)
# 2. installs all tables, triggers, packages and views (sql/install.sql)
# 3. runs the PL/SQL unit test (sql/tests/test_aml_rules.sql)
#
# --rebuild drops every project object first (DEV ONLY).
# ============================================================================
AML_SCRIPT_NAME="setup_db"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd sqlplus
REBUILD="N"
[[ "${1:-}" == "--rebuild" ]] && REBUILD="Y"

[[ -n "${ORACLE_SYSTEM_PASSWORD:-}" ]] || die "Set ORACLE_SYSTEM_PASSWORD to create the schema owner" 2
[[ -n "${AML_DB_PASSWORD:-}" ]] || die "Set AML_DB_PASSWORD (config/aml_pipeline.env) for AML_OWNER" 2

cd "${AML_HOME}"

log_info "Creating schema owner ${AML_DB_USER} (if missing)"
sqlplus -s -L /nolog <<EOF
WHENEVER SQLERROR EXIT FAILURE
connect system/"${ORACLE_SYSTEM_PASSWORD}"@${AML_DB_CONNECT}
@sql/00_setup/00_create_schema_owner.sql "${AML_DB_PASSWORD}"
EXIT SUCCESS
EOF

if [[ "${REBUILD}" == "Y" ]]; then
  log_warn "Dropping all project objects in ${AML_DB_USER}"
  run_sql "@sql/uninstall.sql"
fi

log_info "Installing schema objects"
run_sql "@sql/install.sql"

log_info "Running PL/SQL unit tests"
run_sql "@sql/tests/test_aml_rules.sql"

log_info "Database setup complete"
