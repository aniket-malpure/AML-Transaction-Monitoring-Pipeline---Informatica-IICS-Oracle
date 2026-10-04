-- ============================================================================
-- 05_seed_reference_data.sql   (run as AML_OWNER)
-- Static reference data: calendar, transaction types, unknown members and
-- the starting AML rule thresholds. Safe to rerun (MERGE).
-- ============================================================================

-- Calendar 2024-01-01 .. 2030-12-31
INSERT /*+ APPEND */ INTO dim_date (date_key, cal_date, day_of_week, day_of_month,
                                    month_num, month_name, quarter_num, year_num, is_weekend)
SELECT TO_NUMBER(TO_CHAR(d, 'YYYYMMDD')),
       d,
       TRIM(TO_CHAR(d, 'DAY', 'NLS_DATE_LANGUAGE=ENGLISH')),
       EXTRACT(DAY FROM d),
       EXTRACT(MONTH FROM d),
       TRIM(TO_CHAR(d, 'MONTH', 'NLS_DATE_LANGUAGE=ENGLISH')),
       TO_NUMBER(TO_CHAR(d, 'Q')),
       EXTRACT(YEAR FROM d),
       CASE WHEN TO_CHAR(d, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH') IN ('SAT','SUN') THEN 'Y' ELSE 'N' END
  FROM (SELECT DATE '2024-01-01' + LEVEL - 1 AS d
          FROM dual
       CONNECT BY LEVEL <= DATE '2030-12-31' - DATE '2024-01-01' + 1) cal
 WHERE NOT EXISTS (SELECT 1 FROM dim_date x WHERE x.cal_date = cal.d);
COMMIT;

-- Unknown members (key -1) so a late-arriving dimension never drops a fact
MERGE INTO dim_country t
USING (SELECT -1 AS country_key, 'XX' AS country_code, 'UNKNOWN' AS risk_tier FROM dual) s
ON (t.country_code = s.country_code)
WHEN NOT MATCHED THEN INSERT (country_key, country_code, risk_tier)
                      VALUES (s.country_key, s.country_code, s.risk_tier);

MERGE INTO dim_txn_type t
USING (
  SELECT  1 k, 'CASH_DEP' c, 'BRANCH' ch, 'CR' d, 'Y' cash, 'N' wire, 'Cash deposit at branch'      descr FROM dual UNION ALL
  SELECT  2,   'CASH_WDL',   'ATM',       'DR',   'Y',      'N',      'Cash withdrawal'                    FROM dual UNION ALL
  SELECT  3,   'ACH_IN',     'ACH',       'CR',   'N',      'N',      'Inbound ACH credit'                 FROM dual UNION ALL
  SELECT  4,   'ACH_OUT',    'ACH',       'DR',   'N',      'N',      'Outbound ACH debit'                 FROM dual UNION ALL
  SELECT  5,   'CARD_POS',   'CARD',      'DR',   'N',      'N',      'Debit card purchase'                FROM dual UNION ALL
  SELECT  6,   'WIRE_IN',    'WIRE',      'CR',   'N',      'Y',      'Inbound wire'                       FROM dual UNION ALL
  SELECT  7,   'WIRE_OUT',   'WIRE',      'DR',   'N',      'Y',      'Outbound wire'                      FROM dual UNION ALL
  SELECT  8,   'P2P_IN',     'MOBILE',    'CR',   'N',      'N',      'Peer-to-peer receive'               FROM dual UNION ALL
  SELECT  9,   'P2P_OUT',    'MOBILE',    'DR',   'N',      'N',      'Peer-to-peer send'                  FROM dual UNION ALL
  SELECT -1,   'UNKNOWN',    'UNKNOWN',   'DR',   'N',      'N',      'Unmapped transaction type'          FROM dual
) s
ON (t.txn_type_code = s.c)
WHEN MATCHED THEN UPDATE SET t.channel = s.ch, t.direction = s.d, t.is_cash = s.cash,
                             t.is_wire = s.wire, t.description = s.descr
WHEN NOT MATCHED THEN INSERT (txn_type_key, txn_type_code, channel, direction, is_cash, is_wire, description)
                      VALUES (s.k, s.c, s.ch, s.d, s.cash, s.wire, s.descr);

-- Rule thresholds. Values follow common industry practice for a demo; a real
-- program tunes them with below-the-line testing.
MERGE INTO aml_rule_config t
USING (
  SELECT 'STRUCTURING' code, 'Cash structuring below CTR threshold' nm,
         'Multiple cash deposits each under the CTR threshold that together exceed it within the lookback window.' descr,
         10000 thr, 8000 low, 5 days, 3 cnt, NULL pct, NULL score, NULL idle, 'HIGH' sev, 80 base FROM dual UNION ALL
  SELECT 'LARGE_CASH_CTR', 'Single cash transaction over CTR threshold',
         'Cash deposit or withdrawal above the currency transaction report threshold.',
         10000, NULL, 1, 1, NULL, NULL, NULL, 'MEDIUM', 50 FROM dual UNION ALL
  SELECT 'RAPID_MOVEMENT', 'Rapid movement of funds',
         'Large inbound funds where most of the value leaves the account by wire within the lookback window.',
         25000, NULL, 2, 2, 85, NULL, NULL, 'HIGH', 75 FROM dual UNION ALL
  SELECT 'SANCTIONS_MATCH', 'Counterparty sanctions screening',
         'Wire counterparty name matches an active watchlist entry above the Jaro-Winkler score threshold.',
         NULL, NULL, 1, 1, NULL, 90, NULL, 'CRITICAL', 95 FROM dual UNION ALL
  SELECT 'HIGH_RISK_GEO', 'Wire to prohibited jurisdiction',
         'Outbound or inbound wire with a counterparty in a PROHIBITED country.',
         0, NULL, 1, 1, NULL, NULL, NULL, 'CRITICAL', 90 FROM dual UNION ALL
  SELECT 'DORMANT_REACTIVATION', 'Dormant account sudden activity',
         'Account inactive for 180+ days that moves more than the threshold within the lookback window.',
         10000, NULL, 7, 1, NULL, NULL, 180, 'MEDIUM', 60 FROM dual
) s
ON (t.rule_code = s.code)
WHEN NOT MATCHED THEN INSERT (rule_code, rule_name, description, threshold_amount, lower_bound_amount,
                              lookback_days, min_txn_count, pct_threshold, match_score, inactivity_days,
                              severity, base_risk_score, is_active)
                      VALUES (s.code, s.nm, s.descr, s.thr, s.low, s.days, s.cnt, s.pct, s.score,
                              s.idle, s.sev, s.base, 'Y');
COMMIT;
