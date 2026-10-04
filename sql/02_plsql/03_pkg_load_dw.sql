-- ============================================================================
-- pkg_load_dw.sql   (run as AML_OWNER)
-- Staging -> star schema. Each procedure is idempotent for a batch_id, so the
-- orchestrator can rerun any single step after a failure.
--
-- In IICS mode the staging tables are populated by the m_STG_* mappings and
-- the dimension mappings call these same procedures through a SQL
-- transformation, so the business logic lives in one place (the database)
-- whichever tool is driving.
-- ============================================================================

CREATE OR REPLACE PACKAGE pkg_load_dw AUTHID DEFINER AS

  -- Max share of bad rows tolerated before the load is failed (0.01 = 1%)
  c_max_reject_ratio CONSTANT NUMBER := 0.01;

  PROCEDURE truncate_staging;
  PROCEDURE validate_staging        (p_batch_id IN NUMBER);
  PROCEDURE load_dim_country        (p_batch_id IN NUMBER);
  PROCEDURE load_dim_sanctioned_party (p_batch_id IN NUMBER);
  PROCEDURE load_dim_customer       (p_batch_id IN NUMBER);
  PROCEDURE load_dim_account        (p_batch_id IN NUMBER);
  PROCEDURE load_fact_transaction   (p_batch_id IN NUMBER);
  PROCEDURE gather_stats            (p_batch_id IN NUMBER);

END pkg_load_dw;
/

CREATE OR REPLACE PACKAGE BODY pkg_load_dw AS

  PROCEDURE set_counts (p_read NUMBER, p_written NUMBER, p_rejected NUMBER DEFAULT 0) IS
  BEGIN
    pkg_etl_control.g_rows_read     := p_read;
    pkg_etl_control.g_rows_written  := p_written;
    pkg_etl_control.g_rows_rejected := p_rejected;
  END set_counts;

  -- -------------------------------------------------------------------------
  PROCEDURE truncate_staging IS
  BEGIN
    FOR t IN (SELECT table_name FROM user_tables WHERE table_name LIKE 'STG\_%' ESCAPE '\') LOOP
      EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || DBMS_ASSERT.SIMPLE_SQL_NAME(t.table_name);
    END LOOP;
  END truncate_staging;

  -- -------------------------------------------------------------------------
  -- Reconcile and profile staging before anything touches the warehouse.
  -- Hard failures: file row counts do not match the control file, or the
  -- reject ratio is above c_max_reject_ratio. Soft issues are logged.
  -- -------------------------------------------------------------------------
  PROCEDURE validate_staging (p_batch_id IN NUMBER) IS
    l_total     NUMBER;
    l_bad       NUMBER;
    l_dupes     NUMBER;
    l_mismatch  VARCHAR2(4000);
  BEGIN
    -- 1. Control-file reconciliation (expected rows registered by the shell layer)
    FOR f IN (
      SELECT fa.file_name, fa.expected_rows,
             CASE
               WHEN fa.file_name LIKE 'customers%'      THEN (SELECT COUNT(*) FROM stg_customer     WHERE batch_id = p_batch_id)
               WHEN fa.file_name LIKE 'accounts%'       THEN (SELECT COUNT(*) FROM stg_account      WHERE batch_id = p_batch_id)
               WHEN fa.file_name LIKE 'transactions%'   THEN (SELECT COUNT(*) FROM stg_transaction  WHERE batch_id = p_batch_id)
               WHEN fa.file_name LIKE 'sanctions_list%' THEN (SELECT COUNT(*) FROM stg_sanctions    WHERE batch_id = p_batch_id)
               WHEN fa.file_name LIKE 'country_risk%'   THEN (SELECT COUNT(*) FROM stg_country_risk WHERE batch_id = p_batch_id)
             END AS loaded_rows
        FROM etl_file_audit fa
       WHERE fa.batch_id = p_batch_id)
    LOOP
      UPDATE etl_file_audit
         SET loaded_rows = f.loaded_rows,
             status      = CASE WHEN f.loaded_rows = f.expected_rows THEN 'LOADED' ELSE 'REJECTED' END
       WHERE batch_id = p_batch_id AND file_name = f.file_name;

      IF NVL(f.loaded_rows, -1) <> f.expected_rows THEN
        l_mismatch := l_mismatch || f.file_name || ' expected=' || f.expected_rows
                                 || ' loaded=' || NVL(TO_CHAR(f.loaded_rows), 'n/a') || '; ';
      END IF;
    END LOOP;
    COMMIT;

    IF l_mismatch IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20020, 'Row count reconciliation failed: ' || l_mismatch);
    END IF;

    -- 2. Transaction-level data quality
    SELECT COUNT(*),
           SUM(CASE WHEN txn_id IS NULL
                      OR account_id IS NULL
                      OR VALIDATE_CONVERSION(amount AS NUMBER) = 0
                      OR TO_NUMBER(amount DEFAULT NULL ON CONVERSION ERROR) < 0
                      OR VALIDATE_CONVERSION(txn_ts AS TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') = 0
                      OR direction NOT IN ('CR','DR')
                    THEN 1 ELSE 0 END)
      INTO l_total, l_bad
      FROM stg_transaction
     WHERE batch_id = p_batch_id;

    SELECT COUNT(*) - COUNT(DISTINCT txn_id)
      INTO l_dupes
      FROM stg_transaction
     WHERE batch_id = p_batch_id;

    set_counts(l_total, l_total - NVL(l_bad, 0) - l_dupes, NVL(l_bad, 0) + l_dupes);

    IF l_total = 0 THEN
      RAISE_APPLICATION_ERROR(-20021, 'No transactions staged for batch ' || p_batch_id);
    END IF;

    IF (NVL(l_bad, 0) + l_dupes) / l_total > c_max_reject_ratio THEN
      RAISE_APPLICATION_ERROR(-20022, 'Reject ratio ' ||
        ROUND(100 * (NVL(l_bad, 0) + l_dupes) / l_total, 2) || '% exceeds limit of '
        || (c_max_reject_ratio * 100) || '% (bad=' || l_bad || ', dupes=' || l_dupes || ')');
    END IF;

    IF l_bad > 0 OR l_dupes > 0 THEN
      pkg_aml_util.log_error(p_batch_id, 'VALIDATE_STAGING', NULL,
        'Within tolerance: ' || l_bad || ' malformed and ' || l_dupes || ' duplicate transactions');
    END IF;
  END validate_staging;

  -- -------------------------------------------------------------------------
  PROCEDURE load_dim_country (p_batch_id IN NUMBER) IS
    l_read NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_read FROM stg_country_risk WHERE batch_id = p_batch_id;

    MERGE INTO dim_country t
    USING (SELECT UPPER(TRIM(country_code)) country_code,
                  UPPER(TRIM(risk_tier))    risk_tier
             FROM stg_country_risk
            WHERE batch_id = p_batch_id
              AND country_code IS NOT NULL) s
       ON (t.country_code = s.country_code)
     WHEN MATCHED THEN UPDATE SET t.risk_tier = s.risk_tier, t.updated_ts = SYSTIMESTAMP
                       WHERE t.risk_tier <> s.risk_tier
     WHEN NOT MATCHED THEN INSERT (country_code, risk_tier) VALUES (s.country_code, s.risk_tier);

    set_counts(l_read, SQL%ROWCOUNT);
    COMMIT;
  END load_dim_country;

  -- -------------------------------------------------------------------------
  -- Watchlist is a full snapshot: entries missing from today's file are
  -- deactivated, never deleted (past alerts still reference them).
  -- -------------------------------------------------------------------------
  PROCEDURE load_dim_sanctioned_party (p_batch_id IN NUMBER) IS
    l_read    NUMBER;
    l_written NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_read FROM stg_sanctions WHERE batch_id = p_batch_id;
    IF l_read = 0 THEN
      RAISE_APPLICATION_ERROR(-20030, 'Empty sanctions file: refusing to deactivate the whole watchlist');
    END IF;

    MERGE INTO dim_sanctioned_party t
    USING (SELECT sdn_id, TRIM(party_name) party_name,
                  pkg_aml_util.normalize_name(party_name) party_name_norm,
                  UPPER(party_type) party_type, UPPER(country_code) country_code, list_source
             FROM stg_sanctions
            WHERE batch_id = p_batch_id) s
       ON (t.sdn_id = s.sdn_id)
     WHEN MATCHED THEN UPDATE SET t.party_name = s.party_name, t.party_name_norm = s.party_name_norm,
                                  t.party_type = s.party_type, t.country_code = s.country_code,
                                  t.list_source = s.list_source, t.active_flag = 'Y',
                                  t.updated_ts = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (sdn_id, party_name, party_name_norm, party_type, country_code, list_source)
                           VALUES (s.sdn_id, s.party_name, s.party_name_norm, s.party_type,
                                   s.country_code, s.list_source);
    l_written := SQL%ROWCOUNT;

    UPDATE dim_sanctioned_party t
       SET t.active_flag = 'N', t.updated_ts = SYSTIMESTAMP
     WHERE t.active_flag = 'Y'
       AND NOT EXISTS (SELECT 1 FROM stg_sanctions s
                        WHERE s.batch_id = p_batch_id AND s.sdn_id = t.sdn_id);

    set_counts(l_read, l_written + SQL%ROWCOUNT);
    COMMIT;
  END load_dim_sanctioned_party;

  -- -------------------------------------------------------------------------
  -- SCD Type 2 on KYC-relevant attributes (name, country, KYC rating, PEP).
  -- -------------------------------------------------------------------------
  PROCEDURE load_dim_customer (p_batch_id IN NUMBER) IS
    l_bdate   DATE := pkg_aml_util.business_date(p_batch_id);
    l_read    NUMBER;
    l_expired NUMBER;
    l_new     NUMBER;
    l_delta   NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_read FROM stg_customer WHERE batch_id = p_batch_id;

    -- Latest record per customer in today's file, with a change hash.
    -- tmp_customer_delta is a GTT (ON COMMIT DELETE ROWS).
    INSERT INTO tmp_customer_delta (customer_id, customer_name, customer_type, date_of_birth,
                                    country_code, state_code, kyc_risk_rating, pep_flag,
                                    onboard_date, row_hash)
    SELECT customer_id, customer_name, customer_type,
           TO_DATE(date_of_birth DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'),
           country_code, state_code, kyc_risk_rating, pep_flag,
           TO_DATE(onboard_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'),
           RAWTOHEX(STANDARD_HASH(customer_name || '|' || customer_type || '|' || date_of_birth || '|'
                                  || country_code || '|' || state_code || '|' || kyc_risk_rating
                                  || '|' || pep_flag, 'SHA256'))
      FROM (SELECT s.*, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY load_ts DESC) rn
              FROM stg_customer s
             WHERE batch_id = p_batch_id
               AND customer_id IS NOT NULL
               AND kyc_risk_rating IN ('LOW','MEDIUM','HIGH'))
     WHERE rn = 1;

    -- Close out versions whose attributes changed
    UPDATE dim_customer d
       SET d.eff_end_date = l_bdate - 1,
           d.is_current   = 'N'
     WHERE d.is_current = 'Y'
       AND EXISTS (SELECT 1 FROM tmp_customer_delta s
                    WHERE s.customer_id = d.customer_id
                      AND s.row_hash   <> d.row_hash);
    l_expired := SQL%ROWCOUNT;

    -- Insert brand-new customers and new versions of changed ones.
    -- First version is effective from onboarding so historical transactions resolve.
    INSERT INTO dim_customer (customer_id, customer_name, customer_name_norm, customer_type,
                              date_of_birth, country_code, state_code, kyc_risk_rating, pep_flag,
                              onboard_date, row_hash, eff_start_date, batch_id)
    SELECT s.customer_id, s.customer_name, pkg_aml_util.normalize_name(s.customer_name),
           s.customer_type, s.date_of_birth, s.country_code, s.state_code, s.kyc_risk_rating,
           NVL(s.pep_flag, 'N'), s.onboard_date, s.row_hash,
           CASE WHEN EXISTS (SELECT 1 FROM dim_customer h WHERE h.customer_id = s.customer_id)
                THEN l_bdate
                ELSE LEAST(NVL(s.onboard_date, l_bdate), l_bdate) END,
           p_batch_id
      FROM tmp_customer_delta s
     WHERE NOT EXISTS (SELECT 1 FROM dim_customer d
                        WHERE d.customer_id = s.customer_id AND d.is_current = 'Y');
    l_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO l_delta FROM tmp_customer_delta;
    set_counts(l_read, l_new + l_expired, l_read - l_delta);
    COMMIT;
  END load_dim_customer;

  -- -------------------------------------------------------------------------
  PROCEDURE load_dim_account (p_batch_id IN NUMBER) IS
    l_bdate DATE := pkg_aml_util.business_date(p_batch_id);
    l_idle  NUMBER;
    l_read  NUMBER;
  BEGIN
    SELECT NVL(MAX(inactivity_days), 180) INTO l_idle
      FROM aml_rule_config WHERE rule_code = 'DORMANT_REACTIVATION';

    SELECT COUNT(*) INTO l_read FROM stg_account WHERE batch_id = p_batch_id;

    MERGE INTO dim_account t
    USING (SELECT account_id, customer_id, product_type,
                  TO_DATE(open_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD') open_date,
                  account_status,
                  TO_DATE(last_activity_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD') last_activity_date
             FROM (SELECT a.*, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY load_ts DESC) rn
                     FROM stg_account a
                    WHERE batch_id = p_batch_id AND account_id IS NOT NULL)
            WHERE rn = 1) s
       ON (t.account_id = s.account_id)
     WHEN MATCHED THEN UPDATE SET
            t.customer_id = s.customer_id, t.product_type = s.product_type,
            t.open_date = s.open_date, t.account_status = s.account_status,
            t.last_activity_date = s.last_activity_date,
            t.dormant_flag = CASE WHEN s.last_activity_date < l_bdate - l_idle THEN 'Y' ELSE 'N' END,
            t.updated_ts = SYSTIMESTAMP, t.batch_id = p_batch_id
     WHEN NOT MATCHED THEN INSERT (account_id, customer_id, product_type, open_date, account_status,
                                   last_activity_date, dormant_flag, batch_id)
          VALUES (s.account_id, s.customer_id, s.product_type, s.open_date, s.account_status,
                  s.last_activity_date,
                  CASE WHEN s.last_activity_date < l_bdate - l_idle THEN 'Y' ELSE 'N' END,
                  p_batch_id);

    set_counts(l_read, SQL%ROWCOUNT);
    COMMIT;
  END load_dim_account;

  -- -------------------------------------------------------------------------
  -- Fact load. Already-loaded txn_ids are skipped (safe rerun); constraint
  -- violations go to ERR$_FACT_TRANSACTION; orphan accounts are logged.
  -- -------------------------------------------------------------------------
  PROCEDURE load_fact_transaction (p_batch_id IN NUMBER) IS
    l_tag      VARCHAR2(40) := 'BATCH_' || p_batch_id;
    l_read     NUMBER;
    l_written  NUMBER;
    l_orphans  NUMBER;
    l_errors   NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_read FROM stg_transaction WHERE batch_id = p_batch_id;

    -- Orphans: account not in dim_account. Logged for the source team, not loaded.
    INSERT INTO etl_error_log (error_id, batch_id, step_name, error_code, error_message, record_key)
    SELECT seq_etl_error.NEXTVAL, p_batch_id, 'LOAD_FACT_TRANSACTION', -20040,
           'Account ' || s.account_id || ' not found in DIM_ACCOUNT', s.txn_id
      FROM stg_transaction s
     WHERE s.batch_id = p_batch_id
       AND NOT EXISTS (SELECT 1 FROM dim_account a WHERE a.account_id = s.account_id);
    l_orphans := SQL%ROWCOUNT;

    DELETE FROM err$_fact_transaction WHERE ora_err_tag$ = l_tag;

    INSERT INTO fact_transaction   -- conventional path so LOG ERRORS also captures PK violations
          (txn_id, txn_ts, txn_date, txn_date_key, account_key, customer_key, txn_type_key,
           cp_country_key, direction, amount, signed_amount, currency, counterparty_name,
           counterparty_name_norm, batch_id)
    SELECT s.txn_id,
           s.ts,
           TRUNC(s.ts),
           TO_NUMBER(TO_CHAR(s.ts, 'YYYYMMDD')),
           a.account_key,
           COALESCE(cv.customer_key, cc.customer_key),
           NVL(tt.txn_type_key, -1),
           NVL(dc.country_key, -1),
           s.direction,
           s.amt,
           CASE WHEN s.direction = 'DR' THEN -s.amt ELSE s.amt END,
           NVL(s.currency, 'USD'),
           s.counterparty_name,
           pkg_aml_util.normalize_name(s.counterparty_name),
           p_batch_id
      FROM (SELECT x.*,
                   TO_TIMESTAMP(x.txn_ts DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD HH24:MI:SS') ts,
                   TO_NUMBER(x.amount DEFAULT NULL ON CONVERSION ERROR) amt,
                   ROW_NUMBER() OVER (PARTITION BY x.txn_id ORDER BY x.load_ts) rn
              FROM stg_transaction x
             WHERE x.batch_id = p_batch_id
               AND x.status = 'POSTED') s
      JOIN dim_account a
        ON a.account_id = s.account_id
      LEFT JOIN dim_customer cv                      -- customer version as of txn date
        ON cv.customer_id = a.customer_id
       AND TRUNC(s.ts) BETWEEN cv.eff_start_date AND cv.eff_end_date
      LEFT JOIN dim_customer cc                      -- fallback: current version
        ON cc.customer_id = a.customer_id
       AND cc.is_current = 'Y'
      LEFT JOIN dim_txn_type tt ON tt.txn_type_code = s.txn_type
      LEFT JOIN dim_country  dc ON dc.country_code  = s.counterparty_country
     WHERE s.rn = 1
       AND NOT EXISTS (SELECT 1 FROM fact_transaction f WHERE f.txn_id = s.txn_id)
    LOG ERRORS INTO err$_fact_transaction (l_tag) REJECT LIMIT UNLIMITED;
    l_written := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO l_errors FROM err$_fact_transaction WHERE ora_err_tag$ = l_tag;

    set_counts(l_read, l_written, l_orphans + l_errors);
    COMMIT;

    IF l_read > 0 AND (l_orphans + l_errors) / l_read > c_max_reject_ratio THEN
      RAISE_APPLICATION_ERROR(-20041, 'Fact load rejected ' || (l_orphans + l_errors) || ' of '
        || l_read || ' rows (orphans=' || l_orphans || ', constraint errors=' || l_errors || ')');
    END IF;
  END load_fact_transaction;

  -- -------------------------------------------------------------------------
  PROCEDURE gather_stats (p_batch_id IN NUMBER) IS
  BEGIN
    FOR t IN (SELECT table_name FROM user_tables
               WHERE table_name IN ('DIM_CUSTOMER','DIM_ACCOUNT','FACT_TRANSACTION')) LOOP
      DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => t.table_name,
                                    estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                    method_opt => 'FOR ALL COLUMNS SIZE AUTO',
                                    granularity => 'AUTO', cascade => TRUE, degree => 4);
    END LOOP;
    set_counts(NULL, NULL, NULL);
  END gather_stats;

END pkg_load_dw;
/
