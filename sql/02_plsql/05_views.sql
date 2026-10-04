-- ============================================================================
-- 05_views.sql   (run as AML_OWNER)
-- Reporting views for investigators, the IICS outbound extract and ops.
-- ============================================================================

-- Alert volume and value by rule and day (feeds the tuning dashboard)
CREATE OR REPLACE VIEW v_alert_summary AS
SELECT d.cal_date            AS alert_date,
       a.rule_code,
       r.rule_name,
       a.severity,
       COUNT(*)              AS alert_count,
       COUNT(DISTINCT a.customer_key) AS customers,
       SUM(a.total_amount)   AS total_amount,
       ROUND(AVG(a.risk_score), 1) AS avg_risk_score,
       SUM(CASE WHEN a.alert_status = 'CLOSED_FP'  THEN 1 ELSE 0 END) AS closed_false_positive,
       SUM(CASE WHEN a.alert_status = 'CLOSED_SAR' THEN 1 ELSE 0 END) AS closed_sar
  FROM fact_aml_alert a
  JOIN dim_date d        ON d.date_key  = a.alert_date_key
  JOIN aml_rule_config r ON r.rule_code = a.rule_code
 GROUP BY d.cal_date, a.rule_code, r.rule_name, a.severity;

-- Investigator work queue: open cases ordered by priority then score
CREATE OR REPLACE VIEW v_case_queue AS
SELECT c.case_id,
       c.customer_id,
       cu.customer_name,
       cu.kyc_risk_rating,
       cu.pep_flag,
       c.priority,
       c.max_risk_score,
       c.alert_count,
       c.case_status,
       c.assigned_to,
       c.opened_ts,
       c.last_alert_ts,
       (SELECT LISTAGG(DISTINCT a.rule_code, ', ') WITHIN GROUP (ORDER BY a.rule_code)
          FROM fact_aml_alert a WHERE a.case_id = c.case_id) AS rules_triggered
  FROM aml_case c
  JOIN dim_customer cu ON cu.customer_id = c.customer_id AND cu.is_current = 'Y'
 WHERE c.case_status <> 'CLOSED'
 ORDER BY DECODE(c.priority, 'CRITICAL', 1, 'HIGH', 2, 'MEDIUM', 3, 4), c.max_risk_score DESC;

-- Flat alert extract consumed by m_OUT_AML_ALERT_EXTRACT (one row per alert)
CREATE OR REPLACE VIEW v_alert_extract AS
SELECT a.alert_id,
       a.batch_id,
       a.case_id,
       a.rule_code,
       a.severity,
       a.risk_score,
       TO_CHAR(a.window_start_date, 'YYYY-MM-DD') AS window_start_date,
       TO_CHAR(a.window_end_date,   'YYYY-MM-DD') AS window_end_date,
       acc.account_id,
       cu.customer_id,
       cu.customer_name,
       cu.kyc_risk_rating,
       a.txn_count,
       a.total_amount,
       a.alert_reason,
       a.match_detail,
       a.alert_status,
       TO_CHAR(a.created_ts, 'YYYY-MM-DD"T"HH24:MI:SS') AS created_ts
  FROM fact_aml_alert a
  JOIN dim_account  acc ON acc.account_key = a.account_key
  JOIN dim_customer cu  ON cu.customer_key = a.customer_key;

-- Ops view: last 30 runs with step timings
CREATE OR REPLACE VIEW v_etl_run_status AS
SELECT b.batch_id,
       b.business_date,
       b.status         AS batch_status,
       b.attempt_no,
       b.run_mode,
       s.step_seq,
       s.step_name,
       s.step_type,
       s.status         AS step_status,
       s.rows_read,
       s.rows_written,
       s.rows_rejected,
       ROUND((CAST(s.end_ts AS DATE) - CAST(s.start_ts AS DATE)) * 86400) AS elapsed_sec,
       s.iics_run_id,
       s.message
  FROM etl_batch_run b
  LEFT JOIN etl_step_log s ON s.batch_id = b.batch_id
 WHERE b.business_date >= TRUNC(SYSDATE) - 30;

GRANT SELECT ON v_alert_summary  TO aml_read_role;
GRANT SELECT ON v_case_queue     TO aml_read_role;
GRANT SELECT ON v_alert_extract  TO aml_read_role;
GRANT SELECT ON v_etl_run_status TO aml_read_role;
