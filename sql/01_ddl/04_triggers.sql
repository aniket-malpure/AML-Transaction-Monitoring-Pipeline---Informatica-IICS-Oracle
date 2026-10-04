-- ============================================================================
-- 04_triggers.sql   (run as AML_OWNER, after 03_star_schema.sql)
-- Triggers that enforce audit and case rules no matter who writes the row:
-- the PL/SQL rule engine, an IICS mapping, or an analyst in SQL Developer.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- New alert: stamp audit columns and attach it to the customer's open case,
-- opening one if needed. Investigators work cases, not individual alerts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_alert_bi
BEFORE INSERT ON fact_aml_alert
FOR EACH ROW
DECLARE
  l_customer_id  dim_customer.customer_id%TYPE;
  l_case_id      aml_case.case_id%TYPE;
BEGIN
  :NEW.created_ts := SYSTIMESTAMP;
  :NEW.created_by := NVL(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'), USER);

  IF :NEW.case_id IS NULL THEN
    SELECT customer_id INTO l_customer_id
      FROM dim_customer
     WHERE customer_key = :NEW.customer_key;

    BEGIN
      SELECT case_id INTO l_case_id
        FROM aml_case
       WHERE customer_id = l_customer_id
         AND case_status <> 'CLOSED'
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        INSERT INTO aml_case (customer_key, customer_id, priority, last_alert_ts)
        VALUES (:NEW.customer_key, l_customer_id, :NEW.severity, SYSTIMESTAMP)
        RETURNING case_id INTO l_case_id;
    END;

    :NEW.case_id := l_case_id;
  END IF;

  -- Roll the alert up into the case; escalate case priority if this alert is worse
  UPDATE aml_case c
     SET c.alert_count    = c.alert_count + 1,
         c.max_risk_score = GREATEST(c.max_risk_score, :NEW.risk_score),
         c.last_alert_ts  = SYSTIMESTAMP,
         c.priority       = CASE
                              WHEN DECODE(:NEW.severity,'CRITICAL',4,'HIGH',3,'MEDIUM',2,1)
                                 > DECODE(c.priority,'CRITICAL',4,'HIGH',3,'MEDIUM',2,1)
                              THEN :NEW.severity ELSE c.priority
                            END
   WHERE c.case_id = :NEW.case_id;
END trg_alert_bi;
/

-- ---------------------------------------------------------------------------
-- Alert status changes: enforce the workflow and keep an immutable trail.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_alert_bu
BEFORE UPDATE ON fact_aml_alert
FOR EACH ROW
BEGIN
  -- Evidence columns are frozen once the alert exists
  IF :NEW.rule_code      <> :OLD.rule_code
     OR :NEW.account_key <> :OLD.account_key
     OR :NEW.total_amount <> :OLD.total_amount
     OR :NEW.window_start_date <> :OLD.window_start_date THEN
    RAISE_APPLICATION_ERROR(-20101, 'Alert evidence columns are immutable (alert_id='
                                    || :OLD.alert_id || ')');
  END IF;

  IF :NEW.alert_status <> :OLD.alert_status THEN
    IF :OLD.alert_status IN ('CLOSED_FP','CLOSED_SAR') THEN
      RAISE_APPLICATION_ERROR(-20102, 'Closed alert ' || :OLD.alert_id || ' cannot be reopened');
    END IF;

    INSERT INTO aml_alert_audit (alert_id, old_status, new_status, changed_by)
    VALUES (:OLD.alert_id, :OLD.alert_status, :NEW.alert_status,
            NVL(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'), USER));
  END IF;

  :NEW.updated_ts := SYSTIMESTAMP;
  :NEW.updated_by := NVL(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'), USER);
END trg_alert_bu;
/

-- ---------------------------------------------------------------------------
-- Alerts are regulatory records: never deleted, only dispositioned.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_alert_bd
BEFORE DELETE ON fact_aml_alert
FOR EACH ROW
BEGIN
  RAISE_APPLICATION_ERROR(-20103,
    'Deleting AML alerts is not allowed. Close alert ' || :OLD.alert_id
    || ' with status CLOSED_FP or CLOSED_SAR instead.');
END trg_alert_bd;
/

-- ---------------------------------------------------------------------------
-- Rule threshold changes are versioned for model governance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_rule_config_bu
BEFORE INSERT OR UPDATE ON aml_rule_config
FOR EACH ROW
BEGIN
  :NEW.updated_ts := SYSTIMESTAMP;
  :NEW.updated_by := NVL(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'), USER);
END trg_rule_config_bu;
/

CREATE OR REPLACE TRIGGER trg_rule_config_hist
AFTER INSERT OR UPDATE OR DELETE ON aml_rule_config
FOR EACH ROW
DECLARE
  l_change  VARCHAR2(10);
  l_old     VARCHAR2(4000);
  l_new     VARCHAR2(4000);

  FUNCTION snapshot(p_thr NUMBER, p_low NUMBER, p_days NUMBER, p_cnt NUMBER, p_pct NUMBER,
                    p_score NUMBER, p_idle NUMBER, p_sev VARCHAR2, p_act VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'threshold=' || p_thr || ';lower=' || p_low || ';days=' || p_days
        || ';min_cnt=' || p_cnt || ';pct=' || p_pct || ';match=' || p_score
        || ';inactivity=' || p_idle || ';severity=' || p_sev || ';active=' || p_act;
  END snapshot;
BEGIN
  -- INSERTING/UPDATING/DELETING are PL/SQL predicates, so resolve them before the INSERT
  IF INSERTING THEN
    l_change := 'INSERT';
  ELSIF UPDATING THEN
    l_change := 'UPDATE';
  ELSE
    l_change := 'DELETE';
  END IF;

  IF NOT INSERTING THEN
    l_old := snapshot(:OLD.threshold_amount, :OLD.lower_bound_amount, :OLD.lookback_days,
                      :OLD.min_txn_count, :OLD.pct_threshold, :OLD.match_score,
                      :OLD.inactivity_days, :OLD.severity, :OLD.is_active);
  END IF;
  IF NOT DELETING THEN
    l_new := snapshot(:NEW.threshold_amount, :NEW.lower_bound_amount, :NEW.lookback_days,
                      :NEW.min_txn_count, :NEW.pct_threshold, :NEW.match_score,
                      :NEW.inactivity_days, :NEW.severity, :NEW.is_active);
  END IF;

  INSERT INTO aml_rule_config_hist (rule_code, change_type, old_values, new_values, changed_by)
  VALUES (COALESCE(:NEW.rule_code, :OLD.rule_code), l_change, l_old, l_new,
          NVL(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'), USER));
END trg_rule_config_hist;
/

-- ---------------------------------------------------------------------------
-- Case lifecycle: stamp close time, require a disposition when closing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_case_bu
BEFORE UPDATE OF case_status ON aml_case
FOR EACH ROW
BEGIN
  IF :NEW.case_status = 'CLOSED' AND :OLD.case_status <> 'CLOSED' THEN
    IF :NEW.disposition IS NULL THEN
      RAISE_APPLICATION_ERROR(-20104, 'Case ' || :OLD.case_id || ' needs a disposition before closing');
    END IF;
    :NEW.closed_ts := SYSTIMESTAMP;
  END IF;
END trg_case_bu;
/
