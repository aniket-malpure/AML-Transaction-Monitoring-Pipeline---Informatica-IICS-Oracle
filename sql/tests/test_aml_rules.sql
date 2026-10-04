-- ============================================================================
-- test_aml_rules.sql   (run as AML_OWNER in a DEV/CI schema)
--   sqlplus aml_owner/<pwd>@//localhost:1521/FREEPDB1 @sql/tests/test_aml_rules.sql
--
-- End-to-end unit test of the PL/SQL layer: stages a handful of hand-built
-- rows (one scenario per rule), runs the dimension + fact loads and the rule
-- engine, asserts exactly the expected alerts, reruns to prove idempotency,
-- then removes everything it created. Exits non-zero on any failure so it can
-- gate a CI pipeline.
-- ============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DECLARE
  c_bdate     CONSTANT DATE := DATE '2029-06-30';
  c_pipeline  CONSTANT VARCHAR2(30) := 'AML_UNIT_TEST';
  l_batch     NUMBER;
  l_fail      PLS_INTEGER := 0;
  l_cnt       NUMBER;

  TYPE t_ids IS TABLE OF dim_sanctioned_party.sdn_id%TYPE;
  l_active_sdn t_ids;

  PROCEDURE check_eq (p_label VARCHAR2, p_actual NUMBER, p_expected NUMBER) IS
  BEGIN
    IF NVL(p_actual, -1) = p_expected THEN
      DBMS_OUTPUT.PUT_LINE('  PASS  ' || p_label || ' = ' || p_actual);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  FAIL  ' || p_label || ': expected ' || p_expected || ', got ' || NVL(TO_CHAR(p_actual), 'NULL'));
      l_fail := l_fail + 1;
    END IF;
  END check_eq;

  FUNCTION alerts_for (p_rule VARCHAR2, p_account VARCHAR2) RETURN NUMBER IS
    n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO n
      FROM fact_aml_alert a JOIN dim_account d ON d.account_key = a.account_key
     WHERE a.rule_code = p_rule AND d.account_id = p_account;
    RETURN n;
  END alerts_for;

  PROCEDURE stg_txn (p_id VARCHAR2, p_acct VARCHAR2, p_ts VARCHAR2, p_type VARCHAR2, p_dir VARCHAR2,
                     p_amt NUMBER, p_cp VARCHAR2 DEFAULT NULL, p_cc VARCHAR2 DEFAULT 'US') IS
  BEGIN
    INSERT INTO stg_transaction (batch_id, txn_id, account_id, txn_ts, txn_type, channel, direction,
                                 amount, currency, counterparty_name, counterparty_country, status, src_file_name)
    VALUES (l_batch, p_id, p_acct, p_ts, p_type, 'TEST', p_dir, TO_CHAR(p_amt), 'USD', p_cp, p_cc, 'POSTED', 'unit_test');
  END stg_txn;

  PROCEDURE cleanup IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_alert_bd DISABLE';
    DELETE FROM fact_alert_txn WHERE txn_id LIKE 'UT%';
    DELETE FROM aml_alert_audit WHERE alert_id IN
      (SELECT a.alert_id FROM fact_aml_alert a JOIN dim_account d ON d.account_key = a.account_key
        WHERE d.account_id LIKE 'UTA%');
    DELETE FROM fact_aml_alert WHERE account_key IN (SELECT account_key FROM dim_account WHERE account_id LIKE 'UTA%');
    DELETE FROM aml_case       WHERE customer_id LIKE 'UTC%';
    DELETE FROM fact_transaction WHERE txn_id LIKE 'UT%';
    DELETE FROM err$_fact_transaction WHERE txn_id LIKE 'UT%';
    DELETE FROM dim_account    WHERE account_id LIKE 'UTA%';
    DELETE FROM dim_customer   WHERE customer_id LIKE 'UTC%';
    DELETE FROM dim_sanctioned_party WHERE sdn_id LIKE 'UT-%';
    DELETE FROM etl_error_log  WHERE batch_id IN (SELECT batch_id FROM etl_batch_run WHERE pipeline_name = c_pipeline);
    DELETE FROM etl_step_log   WHERE batch_id IN (SELECT batch_id FROM etl_batch_run WHERE pipeline_name = c_pipeline);
    DELETE FROM etl_file_audit WHERE batch_id IN (SELECT batch_id FROM etl_batch_run WHERE pipeline_name = c_pipeline);
    DELETE FROM etl_batch_run  WHERE pipeline_name = c_pipeline;
    COMMIT;
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_alert_bd ENABLE';
  END cleanup;

BEGIN
  DBMS_OUTPUT.PUT_LINE('AML rule engine unit test');
  cleanup;   -- leftovers from an aborted earlier run

  -- The watchlist load deactivates entries missing from the file; remember
  -- which real entries were active so we can restore them afterwards.
  SELECT sdn_id BULK COLLECT INTO l_active_sdn FROM dim_sanctioned_party WHERE active_flag = 'Y';

  l_batch := pkg_etl_control.start_batch(c_bdate, 'LOCAL', c_pipeline);
  pkg_load_dw.truncate_staging;

  -- ---------------------------------------------------------------- fixtures
  INSERT INTO stg_country_risk (batch_id, country_code, risk_tier) VALUES (l_batch, 'US', 'LOW');
  INSERT INTO stg_country_risk (batch_id, country_code, risk_tier) VALUES (l_batch, 'KY', 'HIGH');
  INSERT INTO stg_country_risk (batch_id, country_code, risk_tier) VALUES (l_batch, 'IR', 'PROHIBITED');

  INSERT INTO stg_sanctions (batch_id, sdn_id, party_name, party_type, country_code, list_source)
  VALUES (l_batch, 'UT-SDN-1', 'Halcyon Maritime Trading LLC', 'ENTITY', 'PA', 'UNIT_TEST');

  INSERT INTO stg_customer (batch_id, customer_id, customer_name, customer_type, date_of_birth, country_code,
                            state_code, kyc_risk_rating, pep_flag, onboard_date)
  VALUES (l_batch, 'UTC000001', 'Test Person One', 'INDIVIDUAL', '1980-02-02', 'US', 'FL', 'HIGH', 'N', '2015-01-01');
  INSERT INTO stg_customer (batch_id, customer_id, customer_name, customer_type, date_of_birth, country_code,
                            state_code, kyc_risk_rating, pep_flag, onboard_date)
  VALUES (l_batch, 'UTC000002', 'Test Imports LLC', 'BUSINESS', NULL, 'US', 'NY', 'LOW', 'N', '2018-05-05');

  INSERT INTO stg_account (batch_id, account_id, customer_id, product_type, open_date, account_status, last_activity_date)
  VALUES (l_batch, 'UTA0000001', 'UTC000001', 'CHECKING', '2015-01-01', 'ACTIVE', '2029-06-29');
  INSERT INTO stg_account (batch_id, account_id, customer_id, product_type, open_date, account_status, last_activity_date)
  VALUES (l_batch, 'UTA0000002', 'UTC000002', 'BUSINESS_CHK', '2018-05-05', 'ACTIVE', '2029-06-29');
  INSERT INTO stg_account (batch_id, account_id, customer_id, product_type, open_date, account_status, last_activity_date)
  VALUES (l_batch, 'UTA0000003', 'UTC000001', 'SAVINGS', '2016-03-03', 'ACTIVE', '2027-01-01');  -- dormant

  -- Structuring: 3 deposits under $10K, $27,300 total in 4 days
  stg_txn('UT0001', 'UTA0000001', '2029-06-20 10:00:00', 'CASH_DEP', 'CR', 9000);
  stg_txn('UT0002', 'UTA0000001', '2029-06-21 11:00:00', 'CASH_DEP', 'CR', 9500);
  stg_txn('UT0003', 'UTA0000001', '2029-06-23 12:00:00', 'CASH_DEP', 'CR', 8800);
  -- CTR: single large cash deposit
  stg_txn('UT0004', 'UTA0000001', '2029-06-25 09:30:00', 'CASH_DEP', 'CR', 15000);
  -- Sanctions: misspelt and punctuated version of the watchlist name
  stg_txn('UT0005', 'UTA0000002', '2029-06-15 14:00:00', 'WIRE_OUT', 'DR', 12000, 'Halcyon Maritme Trading, L.L.C.', 'PA');
  -- High-risk geography
  stg_txn('UT0006', 'UTA0000002', '2029-06-16 15:00:00', 'WIRE_OUT', 'DR', 3000, 'Foreign Beneficiary', 'IR');
  -- Rapid movement: $50K in, $45K wired out next day
  stg_txn('UT0007', 'UTA0000002', '2029-06-10 09:00:00', 'WIRE_IN',  'CR', 50000, 'Sender Co', 'US');
  stg_txn('UT0008', 'UTA0000002', '2029-06-11 16:00:00', 'WIRE_OUT', 'DR', 45000, 'Offshore Beneficiary', 'KY');
  -- Dormant reactivation
  stg_txn('UT0009', 'UTA0000003', '2029-06-27 10:00:00', 'ACH_IN',   'CR', 20000, 'Payroll Inc', 'US');
  -- Noise that must NOT alert
  stg_txn('UT0010', 'UTA0000001', '2029-06-26 18:00:00', 'CARD_POS', 'DR', 42.50, 'Coffee Shop', 'US');
  stg_txn('UT0011', 'UTA0000002', '2029-06-12 10:00:00', 'WIRE_OUT', 'DR', 800, 'Harbor Supplies Inc', 'US');
  COMMIT;

  -- ------------------------------------------------------------------- run
  pkg_load_dw.validate_staging(l_batch);
  pkg_load_dw.load_dim_country(l_batch);
  pkg_load_dw.load_dim_sanctioned_party(l_batch);
  pkg_load_dw.load_dim_customer(l_batch);
  pkg_load_dw.load_dim_account(l_batch);
  pkg_load_dw.load_fact_transaction(l_batch);
  pkg_aml_rules.run_all(l_batch);

  DBMS_OUTPUT.PUT_LINE('Assertions:');
  SELECT COUNT(*) INTO l_cnt FROM fact_transaction WHERE txn_id LIKE 'UT%';
  check_eq('fact rows loaded', l_cnt, 11);

  check_eq('STRUCTURING on UTA0000001',          alerts_for('STRUCTURING',          'UTA0000001'), 1);
  check_eq('LARGE_CASH_CTR on UTA0000001',       alerts_for('LARGE_CASH_CTR',       'UTA0000001'), 1);
  check_eq('SANCTIONS_MATCH on UTA0000002',      alerts_for('SANCTIONS_MATCH',      'UTA0000002'), 1);
  check_eq('HIGH_RISK_GEO on UTA0000002',        alerts_for('HIGH_RISK_GEO',        'UTA0000002'), 1);
  check_eq('RAPID_MOVEMENT on UTA0000002',       alerts_for('RAPID_MOVEMENT',       'UTA0000002'), 1);
  check_eq('DORMANT_REACTIVATION on UTA0000003', alerts_for('DORMANT_REACTIVATION', 'UTA0000003'), 1);

  SELECT COUNT(*) INTO l_cnt
    FROM fact_aml_alert a JOIN dim_account d ON d.account_key = a.account_key
   WHERE d.account_id LIKE 'UTA%';
  check_eq('total alerts', l_cnt, 6);

  SELECT COUNT(*) INTO l_cnt FROM fact_alert_txn WHERE txn_id = 'UT0010';
  check_eq('card purchase linked as evidence', l_cnt, 0);

  SELECT COUNT(*) INTO l_cnt FROM fact_alert_txn x JOIN fact_aml_alert a ON a.alert_id = x.alert_id
   WHERE a.rule_code = 'STRUCTURING';
  check_eq('structuring evidence rows', l_cnt, 3);

  -- Two customers with alerts -> two cases (alerts roll up per customer)
  SELECT COUNT(*) INTO l_cnt FROM aml_case WHERE customer_id LIKE 'UTC%';
  check_eq('cases opened', l_cnt, 2);

  SELECT MAX(priority_rank) INTO l_cnt FROM (
    SELECT DECODE(priority, 'CRITICAL', 4, 'HIGH', 3, 'MEDIUM', 2, 1) priority_rank
      FROM aml_case WHERE customer_id = 'UTC000002');
  check_eq('UTC000002 case escalated to CRITICAL (rank 4)', l_cnt, 4);

  -- -------------------------------------------------------- idempotency
  pkg_load_dw.load_fact_transaction(l_batch);
  check_eq('fact rerun inserts', pkg_etl_control.g_rows_written, 0);

  pkg_aml_rules.run_all(l_batch);
  check_eq('rule rerun new alerts', pkg_etl_control.g_rows_written, 0);

  SELECT COUNT(*) INTO l_cnt FROM fact_alert_txn WHERE txn_id LIKE 'UT%';
  DECLARE
    l_before NUMBER := l_cnt;
  BEGIN
    pkg_aml_rules.run_all(l_batch);
    SELECT COUNT(*) INTO l_cnt FROM fact_alert_txn WHERE txn_id LIKE 'UT%';
    check_eq('evidence rows stable on rerun', l_cnt, l_before);
  END;

  -- --------------------------------------------------------- guard rails
  BEGIN
    DELETE FROM fact_aml_alert WHERE ROWNUM = 1;
    check_eq('alert delete blocked', 0, 1);
  EXCEPTION
    WHEN OTHERS THEN
      check_eq('alert delete blocked (ORA-20103)', SQLCODE, -20103);
  END;

  -- -------------------------------------------------------------- cleanup
  pkg_etl_control.end_batch(l_batch, 'SUCCEEDED');
  cleanup;
  IF l_active_sdn.COUNT > 0 THEN
    FORALL i IN 1 .. l_active_sdn.COUNT
      UPDATE dim_sanctioned_party SET active_flag = 'Y' WHERE sdn_id = l_active_sdn(i);
    COMMIT;
  END IF;

  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, l_fail || ' assertion(s) failed');
  END IF;
  DBMS_OUTPUT.PUT_LINE('All assertions passed.');
END;
/
EXIT SUCCESS
