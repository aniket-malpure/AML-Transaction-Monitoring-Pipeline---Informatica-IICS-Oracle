-- ============================================================================
-- pkg_aml_rules.sql   (run as AML_OWNER)
-- Transaction monitoring scenarios. Thresholds come from AML_RULE_CONFIG so
-- tuning never needs a code release (and every change is versioned by
-- trg_rule_config_hist).
--
-- Every rule is set-based and idempotent: an alert's natural key is
-- (rule_code, account_key, window_start_date), so rerunning a failed night
-- can never create duplicate alerts or double-count a case.
-- ============================================================================

CREATE OR REPLACE PACKAGE pkg_aml_rules AUTHID DEFINER AS

  -- How far back each run scans for patterns (covers the longest lookback
  -- plus late-arriving transactions)
  c_default_scan_days CONSTANT PLS_INTEGER := 30;

  PROCEDURE run_all (p_batch_id IN NUMBER, p_scan_days IN PLS_INTEGER DEFAULT c_default_scan_days);
  PROCEDURE run_rule (p_batch_id IN NUMBER, p_rule_code IN VARCHAR2,
                      p_scan_days IN PLS_INTEGER DEFAULT c_default_scan_days);

  -- Individual scenarios (public so they can be unit tested one at a time)
  FUNCTION rule_structuring          (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER;
  FUNCTION rule_large_cash           (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER;
  FUNCTION rule_rapid_movement       (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER;
  FUNCTION rule_sanctions_match      (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER;
  FUNCTION rule_high_risk_geo        (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER;
  FUNCTION rule_dormant_reactivation (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER;

END pkg_aml_rules;
/

CREATE OR REPLACE PACKAGE BODY pkg_aml_rules AS

  g_cfg aml_rule_config%ROWTYPE;

  PROCEDURE load_config (p_rule_code IN VARCHAR2) IS
  BEGIN
    SELECT * INTO g_cfg FROM aml_rule_config WHERE rule_code = p_rule_code;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20050, 'Rule ' || p_rule_code || ' is not configured');
  END load_config;

  -- Link alerts created in this batch to the transactions that triggered them
  PROCEDURE link_evidence (p_batch_id IN NUMBER, p_rule_code IN VARCHAR2, p_predicate_sql IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE
      'INSERT INTO fact_alert_txn (alert_id, txn_id)
       SELECT DISTINCT a.alert_id, t.txn_id
         FROM fact_aml_alert a
         JOIN fact_transaction t
           ON t.account_key = a.account_key
          AND t.txn_date BETWEEN a.window_start_date AND a.window_end_date
         JOIN dim_txn_type tt ON tt.txn_type_key = t.txn_type_key
         LEFT JOIN dim_country dc ON dc.country_key = t.cp_country_key
        WHERE a.batch_id  = :b
          AND a.rule_code = :r
          AND (' || p_predicate_sql || ')
          AND NOT EXISTS (SELECT 1 FROM fact_alert_txn x
                           WHERE x.alert_id = a.alert_id AND x.txn_id = t.txn_id)'
      USING p_batch_id, p_rule_code;
  END link_evidence;

  -- =========================================================================
  -- STRUCTURING: >= min_txn_count cash deposits each in [lower, threshold)
  -- within lookback_days whose sum exceeds the CTR threshold.
  -- =========================================================================
  FUNCTION rule_structuring (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER IS
    l_rows NUMBER;
  BEGIN
    load_config('STRUCTURING');

    INSERT INTO fact_aml_alert (rule_code, account_key, customer_key, alert_date_key,
                                window_start_date, window_end_date, txn_count, total_amount,
                                risk_score, severity, alert_reason, batch_id)
    WITH cash_deps AS (
      SELECT t.account_key, t.customer_key, t.txn_id, t.txn_date, t.amount
        FROM fact_transaction t
        JOIN dim_txn_type tt ON tt.txn_type_key = t.txn_type_key
       WHERE t.txn_date BETWEEN p_from AND p_to + g_cfg.lookback_days
         AND tt.is_cash = 'Y'
         AND t.direction = 'CR'
         AND t.amount >= g_cfg.lower_bound_amount
         AND t.amount <  g_cfg.threshold_amount)
    SELECT 'STRUCTURING', w.account_key, w.customer_key,
           TO_NUMBER(TO_CHAR(p_to, 'YYYYMMDD')),
           w.txn_date, w.txn_date + g_cfg.lookback_days - 1,
           w.win_cnt, w.win_sum,
           pkg_aml_util.risk_score(g_cfg.base_risk_score, c.kyc_risk_rating, c.pep_flag, w.win_sum),
           g_cfg.severity,
           w.win_cnt || ' cash deposits between $' || g_cfg.lower_bound_amount || ' and $'
             || g_cfg.threshold_amount || ' totalling $' || TO_CHAR(w.win_sum, 'FM999G999G990D00')
             || ' within ' || g_cfg.lookback_days || ' days',
           p_batch_id
      FROM (SELECT x.*,
                   ROW_NUMBER() OVER (PARTITION BY x.account_key ORDER BY x.txn_date, x.txn_id) first_hit
              FROM (-- each qualifying deposit anchors a window [anchor, anchor + lookback - 1]
                    SELECT a.account_key, a.customer_key, a.txn_id, a.txn_date,
                           COUNT(*)      AS win_cnt,
                           SUM(b.amount) AS win_sum
                      FROM cash_deps a
                      JOIN cash_deps b
                        ON b.account_key = a.account_key
                       AND b.txn_date BETWEEN a.txn_date AND a.txn_date + g_cfg.lookback_days - 1
                     GROUP BY a.account_key, a.customer_key, a.txn_id, a.txn_date) x
             WHERE x.win_cnt >= g_cfg.min_txn_count
               AND x.win_sum >  g_cfg.threshold_amount) w
      JOIN dim_customer c ON c.customer_key = w.customer_key
     WHERE w.first_hit = 1
       AND NOT EXISTS (SELECT 1 FROM fact_aml_alert a
                        WHERE a.rule_code = 'STRUCTURING'
                          AND a.account_key = w.account_key
                          AND a.window_start_date = w.txn_date);
    l_rows := SQL%ROWCOUNT;

    link_evidence(p_batch_id, 'STRUCTURING',
      'tt.is_cash = ''Y'' AND t.direction = ''CR'' AND t.amount >= ' || g_cfg.lower_bound_amount
      || ' AND t.amount < ' || g_cfg.threshold_amount);
    RETURN l_rows;
  END rule_structuring;

  -- =========================================================================
  -- LARGE_CASH_CTR: single cash transaction above the CTR threshold
  -- (one alert per account per day).
  -- =========================================================================
  FUNCTION rule_large_cash (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER IS
    l_rows NUMBER;
  BEGIN
    load_config('LARGE_CASH_CTR');

    INSERT INTO fact_aml_alert (rule_code, account_key, customer_key, alert_date_key,
                                window_start_date, window_end_date, txn_count, total_amount,
                                risk_score, severity, alert_reason, batch_id)
    SELECT 'LARGE_CASH_CTR', d.account_key, d.customer_key,
           TO_NUMBER(TO_CHAR(p_to, 'YYYYMMDD')),
           d.txn_date, d.txn_date, d.cnt, d.total,
           pkg_aml_util.risk_score(g_cfg.base_risk_score, c.kyc_risk_rating, c.pep_flag, d.total),
           g_cfg.severity,
           d.cnt || ' cash transaction(s) over $' || g_cfg.threshold_amount || ' on '
             || TO_CHAR(d.txn_date, 'YYYY-MM-DD') || ', largest $' || TO_CHAR(d.max_amt, 'FM999G999G990D00'),
           p_batch_id
      FROM (SELECT t.account_key, MAX(t.customer_key) customer_key, t.txn_date,
                   COUNT(*) cnt, SUM(t.amount) total, MAX(t.amount) max_amt
              FROM fact_transaction t
              JOIN dim_txn_type tt ON tt.txn_type_key = t.txn_type_key
             WHERE t.txn_date BETWEEN p_from AND p_to
               AND tt.is_cash = 'Y'
               AND t.amount > g_cfg.threshold_amount
             GROUP BY t.account_key, t.txn_date) d
      JOIN dim_customer c ON c.customer_key = d.customer_key
     WHERE NOT EXISTS (SELECT 1 FROM fact_aml_alert a
                        WHERE a.rule_code = 'LARGE_CASH_CTR'
                          AND a.account_key = d.account_key
                          AND a.window_start_date = d.txn_date);
    l_rows := SQL%ROWCOUNT;

    link_evidence(p_batch_id, 'LARGE_CASH_CTR',
      'tt.is_cash = ''Y'' AND t.amount > ' || g_cfg.threshold_amount);
    RETURN l_rows;
  END rule_large_cash;

  -- =========================================================================
  -- RAPID_MOVEMENT: credit >= threshold followed by outbound wires totalling
  -- >= pct_threshold% of it within lookback_days.
  -- =========================================================================
  FUNCTION rule_rapid_movement (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER IS
    l_rows NUMBER;
  BEGIN
    load_config('RAPID_MOVEMENT');

    INSERT INTO fact_aml_alert (rule_code, account_key, customer_key, alert_date_key,
                                window_start_date, window_end_date, txn_count, total_amount,
                                risk_score, severity, alert_reason, batch_id)
    SELECT 'RAPID_MOVEMENT', r.account_key, r.customer_key,
           TO_NUMBER(TO_CHAR(p_to, 'YYYYMMDD')),
           r.in_date, r.in_date + g_cfg.lookback_days - 1,
           r.out_cnt + 1, r.in_amount + r.out_amount,
           pkg_aml_util.risk_score(g_cfg.base_risk_score, c.kyc_risk_rating, c.pep_flag, r.in_amount),
           g_cfg.severity,
           '$' || TO_CHAR(r.in_amount, 'FM999G999G990D00') || ' received, $'
             || TO_CHAR(r.out_amount, 'FM999G999G990D00') || ' ('
             || ROUND(100 * r.out_amount / r.in_amount) || '%) wired out within '
             || g_cfg.lookback_days || ' days',
           p_batch_id
      FROM (SELECT i.account_key, i.customer_key, i.txn_date in_date, i.amount in_amount,
                   SUM(o.amount) out_amount, COUNT(o.txn_id) out_cnt,
                   ROW_NUMBER() OVER (PARTITION BY i.account_key ORDER BY i.txn_date, i.txn_id) first_hit
              FROM fact_transaction i
              JOIN fact_transaction o
                ON o.account_key = i.account_key
               AND o.direction   = 'DR'
               AND o.txn_ts      >= i.txn_ts
               AND o.txn_date    <= i.txn_date + g_cfg.lookback_days - 1
              JOIN dim_txn_type ot ON ot.txn_type_key = o.txn_type_key AND ot.is_wire = 'Y'
             WHERE i.txn_date BETWEEN p_from AND p_to
               AND i.direction = 'CR'
               AND i.amount >= g_cfg.threshold_amount
             GROUP BY i.account_key, i.customer_key, i.txn_id, i.txn_date, i.amount
            HAVING SUM(o.amount) >= i.amount * g_cfg.pct_threshold / 100) r
      JOIN dim_customer c ON c.customer_key = r.customer_key
     WHERE r.first_hit = 1
       AND NOT EXISTS (SELECT 1 FROM fact_aml_alert a
                        WHERE a.rule_code = 'RAPID_MOVEMENT'
                          AND a.account_key = r.account_key
                          AND a.window_start_date = r.in_date);
    l_rows := SQL%ROWCOUNT;

    link_evidence(p_batch_id, 'RAPID_MOVEMENT',
      '(t.direction = ''CR'' AND t.amount >= ' || g_cfg.threshold_amount
      || ') OR (t.direction = ''DR'' AND tt.is_wire = ''Y'')');
    RETURN l_rows;
  END rule_rapid_movement;

  -- =========================================================================
  -- SANCTIONS_MATCH: wire counterparty vs active watchlist, fuzzy matched with
  -- Jaro-Winkler on normalised names so typos and punctuation do not hide a hit.
  -- Blocking on first letter keeps the comparison set small.
  -- =========================================================================
  FUNCTION rule_sanctions_match (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER IS
    l_rows NUMBER;
  BEGIN
    load_config('SANCTIONS_MATCH');

    INSERT INTO fact_aml_alert (rule_code, account_key, customer_key, alert_date_key,
                                window_start_date, window_end_date, txn_count, total_amount,
                                risk_score, severity, alert_reason, match_detail, batch_id)
    SELECT 'SANCTIONS_MATCH', m.account_key, m.customer_key,
           TO_NUMBER(TO_CHAR(p_to, 'YYYYMMDD')),
           m.txn_date, m.txn_date, m.cnt, m.total,
           -- a watchlist hit is always top priority regardless of customer profile
           GREATEST(pkg_aml_util.risk_score(g_cfg.base_risk_score, c.kyc_risk_rating, c.pep_flag, m.total),
                    g_cfg.base_risk_score),
           g_cfg.severity,
           'Wire counterparty "' || m.counterparty_name || '" matches watchlist entry '
             || m.sdn_id || ' (' || m.party_name || ')',
           'sdn_id=' || m.sdn_id || ';jw_score=' || m.best_score || ';list=' || m.list_source,
           p_batch_id
      FROM (SELECT h.*,
                   COUNT(*)      OVER (PARTITION BY h.account_key, h.txn_date) cnt,
                   SUM(h.amount) OVER (PARTITION BY h.account_key, h.txn_date) total,
                   ROW_NUMBER()  OVER (PARTITION BY h.account_key, h.txn_date
                                       ORDER BY h.best_score DESC, h.txn_id) rn
              FROM (SELECT t.txn_id, t.account_key, t.customer_key, t.txn_date, t.amount,
                           t.counterparty_name, s.sdn_id, s.party_name, s.list_source,
                           UTL_MATCH.JARO_WINKLER_SIMILARITY(t.counterparty_name_norm, s.party_name_norm) best_score,
                           ROW_NUMBER() OVER (PARTITION BY t.txn_id
                             ORDER BY UTL_MATCH.JARO_WINKLER_SIMILARITY(t.counterparty_name_norm, s.party_name_norm) DESC) best_sdn
                      FROM fact_transaction t
                      JOIN dim_txn_type tt ON tt.txn_type_key = t.txn_type_key AND tt.is_wire = 'Y'
                      JOIN dim_sanctioned_party s
                        ON s.active_flag = 'Y'
                       AND SUBSTR(s.party_name_norm, 1, 1) = SUBSTR(t.counterparty_name_norm, 1, 1)
                     WHERE t.txn_date BETWEEN p_from AND p_to
                       AND t.counterparty_name_norm IS NOT NULL
                       AND UTL_MATCH.JARO_WINKLER_SIMILARITY(t.counterparty_name_norm, s.party_name_norm)
                           >= g_cfg.match_score) h
             WHERE h.best_sdn = 1) m
      JOIN dim_customer c ON c.customer_key = m.customer_key
     WHERE m.rn = 1
       AND NOT EXISTS (SELECT 1 FROM fact_aml_alert a
                        WHERE a.rule_code = 'SANCTIONS_MATCH'
                          AND a.account_key = m.account_key
                          AND a.window_start_date = m.txn_date);
    l_rows := SQL%ROWCOUNT;

    link_evidence(p_batch_id, 'SANCTIONS_MATCH',
      'tt.is_wire = ''Y'' AND EXISTS (SELECT 1 FROM dim_sanctioned_party s WHERE s.active_flag = ''Y''
         AND UTL_MATCH.JARO_WINKLER_SIMILARITY(t.counterparty_name_norm, s.party_name_norm) >= '
      || g_cfg.match_score || ')');
    RETURN l_rows;
  END rule_sanctions_match;

  -- =========================================================================
  -- HIGH_RISK_GEO: any wire with a counterparty in a PROHIBITED jurisdiction
  -- =========================================================================
  FUNCTION rule_high_risk_geo (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER IS
    l_rows NUMBER;
  BEGIN
    load_config('HIGH_RISK_GEO');

    INSERT INTO fact_aml_alert (rule_code, account_key, customer_key, alert_date_key,
                                window_start_date, window_end_date, txn_count, total_amount,
                                risk_score, severity, alert_reason, match_detail, batch_id)
    SELECT 'HIGH_RISK_GEO', g.account_key, g.customer_key,
           TO_NUMBER(TO_CHAR(p_to, 'YYYYMMDD')),
           g.txn_date, g.txn_date, g.cnt, g.total,
           pkg_aml_util.risk_score(g_cfg.base_risk_score, c.kyc_risk_rating, c.pep_flag, g.total),
           g_cfg.severity,
           g.cnt || ' wire(s) totalling $' || TO_CHAR(g.total, 'FM999G999G990D00')
             || ' with counterparties in prohibited jurisdiction(s): ' || g.countries,
           'countries=' || g.countries,
           p_batch_id
      FROM (SELECT t.account_key, MAX(t.customer_key) customer_key, t.txn_date,
                   COUNT(*) cnt, SUM(t.amount) total,
                   LISTAGG(DISTINCT dc.country_code, ',') WITHIN GROUP (ORDER BY dc.country_code) countries
              FROM fact_transaction t
              JOIN dim_txn_type tt ON tt.txn_type_key = t.txn_type_key AND tt.is_wire = 'Y'
              JOIN dim_country  dc ON dc.country_key  = t.cp_country_key
             WHERE t.txn_date BETWEEN p_from AND p_to
               AND dc.risk_tier = 'PROHIBITED'
               AND t.amount > NVL(g_cfg.threshold_amount, 0)
             GROUP BY t.account_key, t.txn_date) g
      JOIN dim_customer c ON c.customer_key = g.customer_key
     WHERE NOT EXISTS (SELECT 1 FROM fact_aml_alert a
                        WHERE a.rule_code = 'HIGH_RISK_GEO'
                          AND a.account_key = g.account_key
                          AND a.window_start_date = g.txn_date);
    l_rows := SQL%ROWCOUNT;

    link_evidence(p_batch_id, 'HIGH_RISK_GEO', 'tt.is_wire = ''Y'' AND dc.risk_tier = ''PROHIBITED''');
    RETURN l_rows;
  END rule_high_risk_geo;

  -- =========================================================================
  -- DORMANT_REACTIVATION: account flagged dormant (no activity for
  -- inactivity_days before this load) moving more than threshold_amount.
  -- =========================================================================
  FUNCTION rule_dormant_reactivation (p_batch_id NUMBER, p_from DATE, p_to DATE) RETURN NUMBER IS
    l_rows NUMBER;
  BEGIN
    load_config('DORMANT_REACTIVATION');

    INSERT INTO fact_aml_alert (rule_code, account_key, customer_key, alert_date_key,
                                window_start_date, window_end_date, txn_count, total_amount,
                                risk_score, severity, alert_reason, batch_id)
    SELECT 'DORMANT_REACTIVATION', d.account_key, d.customer_key,
           TO_NUMBER(TO_CHAR(p_to, 'YYYYMMDD')),
           d.first_date, d.first_date + g_cfg.lookback_days - 1, d.cnt, d.total,
           pkg_aml_util.risk_score(g_cfg.base_risk_score, c.kyc_risk_rating, c.pep_flag, d.total),
           g_cfg.severity,
           'Account dormant since ' || TO_CHAR(d.last_activity_date, 'YYYY-MM-DD') || ' moved $'
             || TO_CHAR(d.total, 'FM999G999G990D00') || ' across ' || d.cnt || ' transaction(s)',
           p_batch_id
      FROM (SELECT t.account_key, MAX(t.customer_key) customer_key, a.last_activity_date,
                   MIN(t.txn_date) first_date, COUNT(*) cnt, SUM(t.amount) total
              FROM fact_transaction t
              JOIN dim_account a ON a.account_key = t.account_key
             WHERE a.dormant_flag = 'Y'
               AND t.txn_date BETWEEN p_from AND p_to
             GROUP BY t.account_key, a.last_activity_date
            HAVING SUM(t.amount) > g_cfg.threshold_amount) d
      JOIN dim_customer c ON c.customer_key = d.customer_key
     WHERE NOT EXISTS (SELECT 1 FROM fact_aml_alert a
                        WHERE a.rule_code = 'DORMANT_REACTIVATION'
                          AND a.account_key = d.account_key
                          AND a.window_start_date = d.first_date);
    l_rows := SQL%ROWCOUNT;

    link_evidence(p_batch_id, 'DORMANT_REACTIVATION', '1 = 1');
    RETURN l_rows;
  END rule_dormant_reactivation;

  -- =========================================================================
  -- Dispatcher
  -- =========================================================================
  FUNCTION dispatch (p_batch_id NUMBER, p_rule_code VARCHAR2, p_from DATE, p_to DATE) RETURN NUMBER IS
  BEGIN
    RETURN CASE p_rule_code
             WHEN 'STRUCTURING'          THEN rule_structuring(p_batch_id, p_from, p_to)
             WHEN 'LARGE_CASH_CTR'       THEN rule_large_cash(p_batch_id, p_from, p_to)
             WHEN 'RAPID_MOVEMENT'       THEN rule_rapid_movement(p_batch_id, p_from, p_to)
             WHEN 'SANCTIONS_MATCH'      THEN rule_sanctions_match(p_batch_id, p_from, p_to)
             WHEN 'HIGH_RISK_GEO'        THEN rule_high_risk_geo(p_batch_id, p_from, p_to)
             WHEN 'DORMANT_REACTIVATION' THEN rule_dormant_reactivation(p_batch_id, p_from, p_to)
           END;
  END dispatch;

  PROCEDURE run_rule (p_batch_id IN NUMBER, p_rule_code IN VARCHAR2,
                      p_scan_days IN PLS_INTEGER DEFAULT c_default_scan_days) IS
    l_to   DATE := pkg_aml_util.business_date(p_batch_id);
    l_rows NUMBER;
  BEGIN
    l_rows := dispatch(p_batch_id, p_rule_code, l_to - p_scan_days, l_to);
    IF l_rows IS NULL THEN
      RAISE_APPLICATION_ERROR(-20051, 'No implementation for rule ' || p_rule_code);
    END IF;
    pkg_etl_control.g_rows_written := l_rows;
    COMMIT;
  END run_rule;

  -- Runs every active rule. One rule failing does not stop the others: each
  -- rule commits on its own, failures are logged, and the step is failed at
  -- the end so the orchestrator reruns it (already-raised alerts are skipped).
  PROCEDURE run_all (p_batch_id IN NUMBER, p_scan_days IN PLS_INTEGER DEFAULT c_default_scan_days) IS
    l_to      DATE := pkg_aml_util.business_date(p_batch_id);
    l_from    DATE := l_to - p_scan_days;
    l_rows    NUMBER;
    l_total   NUMBER := 0;
    l_failed  VARCHAR2(400);
  BEGIN
    DBMS_APPLICATION_INFO.SET_MODULE('AML_RULES', 'batch ' || p_batch_id);

    FOR r IN (SELECT rule_code FROM aml_rule_config WHERE is_active = 'Y' ORDER BY rule_code) LOOP
      BEGIN
        DBMS_APPLICATION_INFO.SET_ACTION(r.rule_code);
        SAVEPOINT before_rule;
        l_rows  := dispatch(p_batch_id, r.rule_code, l_from, l_to);
        l_total := l_total + NVL(l_rows, 0);
        COMMIT;
        DBMS_OUTPUT.PUT_LINE(RPAD(r.rule_code, 24) || NVL(l_rows, 0) || ' new alert(s)');
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK TO before_rule;
          pkg_aml_util.log_error(p_batch_id, 'RULE_' || r.rule_code);
          l_failed := l_failed || r.rule_code || ' ';
      END;
    END LOOP;

    pkg_etl_control.g_rows_written := l_total;
    DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);

    IF l_failed IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20052, 'Rules failed: ' || TRIM(l_failed)
        || '. See ETL_ERROR_LOG for batch ' || p_batch_id);
    END IF;
  END run_all;

END pkg_aml_rules;
/
