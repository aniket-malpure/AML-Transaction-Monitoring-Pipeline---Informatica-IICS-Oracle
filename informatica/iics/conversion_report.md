# PowerCenter to IICS conversion report

Generated 2026-10-01 17:42 UTC by `tools/pc_to_iics/convert_pc_to_iics.py`.

| Workflows | Auto | Auto with warnings | Manual follow-up | Transformations | Expressions |
|---|---|---|---|---|---|
| 12 | 1 | 10 | 1 | 16 | 33 |

## By workflow

| PowerCenter workflow | IICS mapping | Status | Findings |
|---|---|---|---|
| wf_AML_RULE_EXECUTION | m_AML_RULE_EXECUTION | AUTO_WITH_WARNINGS | 2 |
| wf_DIM_ACCOUNT_LOAD | m_DIM_ACCOUNT_LOAD | MANUAL | 2 |
| wf_DIM_COUNTRY_LOAD | m_DIM_COUNTRY_LOAD | AUTO_WITH_WARNINGS | 1 |
| wf_DIM_CUSTOMER_SCD2 | m_DIM_CUSTOMER_SCD2 | AUTO_WITH_WARNINGS | 1 |
| wf_DIM_SANCTIONED_PARTY_LOAD | m_DIM_SANCTIONED_PARTY_LOAD | AUTO | 0 |
| wf_FACT_TRANSACTION_LOAD | m_FACT_TRANSACTION_LOAD | AUTO_WITH_WARNINGS | 3 |
| wf_OUT_AML_ALERT_EXTRACT | m_OUT_AML_ALERT_EXTRACT | AUTO_WITH_WARNINGS | 1 |
| wf_STG_ACCOUNT_LOAD | m_STG_ACCOUNT_LOAD | AUTO_WITH_WARNINGS | 1 |
| wf_STG_COUNTRY_RISK_LOAD | m_STG_COUNTRY_RISK_LOAD | AUTO_WITH_WARNINGS | 1 |
| wf_STG_CUSTOMER_LOAD | m_STG_CUSTOMER_LOAD | AUTO_WITH_WARNINGS | 1 |
| wf_STG_SANCTIONS_LOAD | m_STG_SANCTIONS_LOAD | AUTO_WITH_WARNINGS | 1 |
| wf_STG_TRANSACTION_LOAD | m_STG_TRANSACTION_LOAD | AUTO_WITH_WARNINGS | 3 |

## Findings

### wf_AML_RULE_EXECUTION (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `SQ_DUAL`: SQL override carried over as a Query source. Re-validate the field order against the query's select list in the Mapping Designer.
- **AUTO_WITH_WARNINGS** `SP_RUN_AML_RULES`: Stored Procedure transformation converted to a SQL transformation calling PKG_AML_RULES.RUN_ALL. Verify parameter binding.

### wf_DIM_ACCOUNT_LOAD (MANUAL)

- **MANUAL** `LKP_RULE_INACTIVITY_DAYS`: Lookup Procedure 'LKP_RULE_INACTIVITY_DAYS' is referenced but not in the export (reusable or unconnected). Export it with dependencies or rebuild it in IICS.
- **MANUAL** `EXP_DORMANT_FLAG.v_IDLE_DAYS`: Unconnected lookup call LKP_RULE_INACTIVITY_DAYS: create an unconnected Lookup transformation with a return field in the IICS mapping; the :LKP. syntax is kept.

### wf_DIM_COUNTRY_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `UPD_COUNTRY`: Conditional Update Strategy folded into target operation 'Data Driven' with condition: IIF(ISNULL(LKP_COUNTRY_KEY), DD_INSERT, DD_UPDATE)

### wf_DIM_CUSTOMER_SCD2 (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `LKP_DIM_CUSTOMER_CURRENT`: Lookup SQL override kept; IICS requires override columns to match lookup field names.

### wf_FACT_TRANSACTION_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `SQ_STG_TRANSACTION`: SQL override carried over as a Query source. Re-validate the field order against the query's select list in the Mapping Designer.
- **AUTO_WITH_WARNINGS** `EXP_DERIVE.LOAD_TS`: SESSSTARTTIME is evaluated on the Secure Agent clock in IICS; confirm time zone (UTC vs EST).
- **AUTO_WITH_WARNINGS** `FACT_TRANSACTION`: Bulk load mode: confirm the Oracle connector bulk option is licensed/enabled and that no indexes/triggers on the target block direct-path load.

### wf_OUT_AML_ALERT_EXTRACT (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `s_m_OUT_AML_ALERT_EXTRACT`: Post-session command moved to the mapping task postprocessing command; the script must exist on the Secure Agent host.

### wf_STG_ACCOUNT_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `accounts`: Source directory used $PMSourceFileDir; mapped to in-out parameter $$SRC_FILE_DIR (set in the parameter file / flat-file connection).

### wf_STG_COUNTRY_RISK_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `country_risk`: Source directory used $PMSourceFileDir; mapped to in-out parameter $$SRC_FILE_DIR (set in the parameter file / flat-file connection).

### wf_STG_CUSTOMER_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `customers`: Source directory used $PMSourceFileDir; mapped to in-out parameter $$SRC_FILE_DIR (set in the parameter file / flat-file connection).

### wf_STG_SANCTIONS_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `sanctions_list`: Source directory used $PMSourceFileDir; mapped to in-out parameter $$SRC_FILE_DIR (set in the parameter file / flat-file connection).

### wf_STG_TRANSACTION_LOAD (AUTO_WITH_WARNINGS)

- **AUTO_WITH_WARNINGS** `transactions`: Source directory used $PMSourceFileDir; mapped to in-out parameter $$SRC_FILE_DIR (set in the parameter file / flat-file connection).
- **AUTO_WITH_WARNINGS** `STG_TRANSACTION`: Bulk load mode: confirm the Oracle connector bulk option is licensed/enabled and that no indexes/triggers on the target block direct-path load.
- **AUTO_WITH_WARNINGS** `cmd_validate_control_file`: Command task converted to a taskflow Command Task; it runs on the Secure Agent, so script paths and permissions must be redeployed there.
