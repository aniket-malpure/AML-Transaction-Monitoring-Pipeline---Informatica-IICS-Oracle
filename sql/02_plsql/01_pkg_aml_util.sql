-- ============================================================================
-- pkg_aml_util.sql   (run as AML_OWNER)
-- Shared helpers: name normalisation for screening, autonomous error logging,
-- and the risk score formula used by every rule.
-- ============================================================================

CREATE OR REPLACE PACKAGE pkg_aml_util AUTHID DEFINER AS

  -- Upper-case, strip punctuation and legal-entity noise words so that
  -- "Halcyon Maritime Trading, L.L.C." and "HALCYON MARITIME TRADING LLC"
  -- compare as the same string before Jaro-Winkler scoring.
  FUNCTION normalize_name (p_name IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC;

  -- Base rule score adjusted for customer risk factors, capped at 100.
  FUNCTION risk_score (p_base_score IN NUMBER,
                       p_kyc_rating IN VARCHAR2,
                       p_pep_flag   IN VARCHAR2,
                       p_amount     IN NUMBER DEFAULT NULL) RETURN NUMBER DETERMINISTIC;

  -- Writes to ETL_ERROR_LOG in its own transaction, so the log survives
  -- the caller's rollback.
  PROCEDURE log_error (p_batch_id   IN NUMBER,
                       p_step_name  IN VARCHAR2,
                       p_record_key IN VARCHAR2 DEFAULT NULL,
                       p_message    IN VARCHAR2 DEFAULT NULL);

  FUNCTION business_date (p_batch_id IN NUMBER) RETURN DATE;

END pkg_aml_util;
/

CREATE OR REPLACE PACKAGE BODY pkg_aml_util AS

  FUNCTION normalize_name (p_name IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC IS
    PRAGMA UDF;
    l_name VARCHAR2(400);
  BEGIN
    IF p_name IS NULL THEN
      RETURN NULL;
    END IF;
    l_name := UPPER(p_name);
    l_name := REGEXP_REPLACE(l_name, '[^A-Z0-9 ]', '');          -- drop punctuation
    l_name := TRIM(REGEXP_REPLACE(l_name, ' {2,}', ' '));         -- collapse spaces
    l_name := REGEXP_REPLACE(l_name,                              -- drop one legal suffix
                ' (LLC|LTD|LIMITED|INC|CORP|CO|FZE|PLC|SA|GMBH|HOLDINGS?)$', '');
    RETURN TRIM(l_name);
  END normalize_name;

  FUNCTION risk_score (p_base_score IN NUMBER,
                       p_kyc_rating IN VARCHAR2,
                       p_pep_flag   IN VARCHAR2,
                       p_amount     IN NUMBER DEFAULT NULL) RETURN NUMBER DETERMINISTIC IS
    PRAGMA UDF;
    l_score NUMBER := NVL(p_base_score, 0);
  BEGIN
    l_score := l_score
             + CASE p_kyc_rating WHEN 'HIGH' THEN 10 WHEN 'MEDIUM' THEN 5 ELSE 0 END
             + CASE WHEN p_pep_flag = 'Y' THEN 10 ELSE 0 END
             + CASE WHEN NVL(p_amount, 0) >= 100000 THEN 5 ELSE 0 END;
    RETURN LEAST(100, GREATEST(0, ROUND(l_score)));
  END risk_score;

  PROCEDURE log_error (p_batch_id   IN NUMBER,
                       p_step_name  IN VARCHAR2,
                       p_record_key IN VARCHAR2 DEFAULT NULL,
                       p_message    IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO etl_error_log (error_id, batch_id, step_name, error_code, error_message,
                               error_backtrace, record_key)
    VALUES (seq_etl_error.NEXTVAL, p_batch_id, p_step_name, SQLCODE,
            SUBSTR(NVL(p_message, SQLERRM), 1, 4000),
            SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
            p_record_key);
    COMMIT;
  END log_error;

  FUNCTION business_date (p_batch_id IN NUMBER) RETURN DATE IS
    l_dt DATE;
  BEGIN
    SELECT business_date INTO l_dt FROM etl_batch_run WHERE batch_id = p_batch_id;
    RETURN l_dt;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'Unknown batch_id ' || p_batch_id);
  END business_date;

END pkg_aml_util;
/
