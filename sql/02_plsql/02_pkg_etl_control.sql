-- ============================================================================
-- pkg_etl_control.sql   (run as AML_OWNER)
-- Batch and step bookkeeping for the nightly AML chain.
--
-- Restart model: a business date has at most one batch_id. If the previous
-- attempt FAILED, start_batch reuses that batch_id and bumps attempt_no, and
-- the orchestrator skips every step already marked SUCCEEDED. Because the
-- loads and rules are idempotent, rerunning a step is always safe, but we only
-- rerun what actually failed.
-- ============================================================================

CREATE OR REPLACE PACKAGE pkg_etl_control AUTHID DEFINER AS

  c_pipeline CONSTANT VARCHAR2(30) := 'AML_NIGHTLY';

  -- Row counters a load procedure sets for end_step to record
  g_rows_read     NUMBER;
  g_rows_written  NUMBER;
  g_rows_rejected NUMBER;

  FUNCTION start_batch (p_business_date IN DATE,
                        p_run_mode      IN VARCHAR2 DEFAULT 'IICS',
                        p_pipeline      IN VARCHAR2 DEFAULT c_pipeline,
                        p_force_rerun   IN VARCHAR2 DEFAULT 'N') RETURN NUMBER;

  PROCEDURE end_batch (p_batch_id IN NUMBER, p_status IN VARCHAR2);

  FUNCTION step_succeeded (p_batch_id IN NUMBER, p_step_name IN VARCHAR2) RETURN VARCHAR2;

  FUNCTION start_step (p_batch_id    IN NUMBER,
                       p_step_seq    IN NUMBER,
                       p_step_name   IN VARCHAR2,
                       p_step_type   IN VARCHAR2,
                       p_iics_run_id IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;

  PROCEDURE end_step (p_step_log_id   IN NUMBER,
                      p_status        IN VARCHAR2 DEFAULT 'SUCCEEDED',
                      p_rows_read     IN NUMBER   DEFAULT NULL,
                      p_rows_written  IN NUMBER   DEFAULT NULL,
                      p_rows_rejected IN NUMBER   DEFAULT NULL,
                      p_message       IN VARCHAR2 DEFAULT NULL);

  PROCEDURE register_file (p_batch_id      IN NUMBER,
                           p_file_name     IN VARCHAR2,
                           p_expected_rows IN NUMBER,
                           p_md5           IN VARCHAR2,
                           p_status        IN VARCHAR2 DEFAULT 'VALIDATED');

  PROCEDURE reset_counters;

END pkg_etl_control;
/

CREATE OR REPLACE PACKAGE BODY pkg_etl_control AS

  FUNCTION start_batch (p_business_date IN DATE,
                        p_run_mode      IN VARCHAR2 DEFAULT 'IICS',
                        p_pipeline      IN VARCHAR2 DEFAULT c_pipeline,
                        p_force_rerun   IN VARCHAR2 DEFAULT 'N') RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_batch_id  etl_batch_run.batch_id%TYPE;
    l_status    etl_batch_run.status%TYPE;
  BEGIN
    SELECT MAX(batch_id)
      INTO l_batch_id
      FROM etl_batch_run
     WHERE pipeline_name = p_pipeline
       AND business_date = TRUNC(p_business_date);

    IF l_batch_id IS NOT NULL THEN
      SELECT status INTO l_status
        FROM etl_batch_run
       WHERE batch_id = l_batch_id
         FOR UPDATE;
    END IF;

    IF l_batch_id IS NULL THEN
      l_batch_id := seq_etl_batch.NEXTVAL;
      INSERT INTO etl_batch_run (batch_id, business_date, pipeline_name, status, run_mode)
      VALUES (l_batch_id, TRUNC(p_business_date), p_pipeline, 'RUNNING', p_run_mode);

    ELSIF l_status = 'RUNNING' THEN
      ROLLBACK;
      RAISE_APPLICATION_ERROR(-20010, 'Batch ' || l_batch_id || ' for '
        || TO_CHAR(p_business_date, 'YYYY-MM-DD') || ' is still RUNNING. '
        || 'Abort it before starting another attempt.');

    ELSIF l_status = 'SUCCEEDED' AND p_force_rerun <> 'Y' THEN
      ROLLBACK;
      RAISE_APPLICATION_ERROR(-20011, 'Business date ' || TO_CHAR(p_business_date, 'YYYY-MM-DD')
        || ' already SUCCEEDED in batch ' || l_batch_id || '. Use force rerun to reprocess.');

    ELSIF l_status = 'SUCCEEDED' AND p_force_rerun = 'Y' THEN
      -- Forced full reprocess: new batch, every step runs again
      l_batch_id := seq_etl_batch.NEXTVAL;
      INSERT INTO etl_batch_run (batch_id, business_date, pipeline_name, status, run_mode)
      VALUES (l_batch_id, TRUNC(p_business_date), p_pipeline, 'RUNNING', p_run_mode);

    ELSE
      -- FAILED or ABORTED: restart the same batch from the failed step
      UPDATE etl_batch_run
         SET status     = 'RUNNING',
             attempt_no = attempt_no + 1,
             run_mode   = p_run_mode,
             start_ts   = SYSTIMESTAMP,
             end_ts     = NULL
       WHERE batch_id = l_batch_id;
    END IF;

    COMMIT;
    RETURN l_batch_id;
  END start_batch;

  PROCEDURE end_batch (p_batch_id IN NUMBER, p_status IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE etl_batch_run
       SET status = p_status,
           end_ts = SYSTIMESTAMP
     WHERE batch_id = p_batch_id;

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      RAISE_APPLICATION_ERROR(-20012, 'Unknown batch_id ' || p_batch_id);
    END IF;
    COMMIT;
  END end_batch;

  FUNCTION step_succeeded (p_batch_id IN NUMBER, p_step_name IN VARCHAR2) RETURN VARCHAR2 IS
    l_cnt PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_cnt
      FROM etl_step_log
     WHERE batch_id  = p_batch_id
       AND step_name = p_step_name
       AND status    = 'SUCCEEDED';
    RETURN CASE WHEN l_cnt > 0 THEN 'Y' ELSE 'N' END;
  END step_succeeded;

  FUNCTION start_step (p_batch_id    IN NUMBER,
                       p_step_seq    IN NUMBER,
                       p_step_name   IN VARCHAR2,
                       p_step_type   IN VARCHAR2,
                       p_iics_run_id IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_id etl_step_log.step_log_id%TYPE := seq_etl_step.NEXTVAL;
  BEGIN
    INSERT INTO etl_step_log (step_log_id, batch_id, step_seq, step_name, step_type, status, iics_run_id)
    VALUES (l_id, p_batch_id, p_step_seq, p_step_name, p_step_type, 'RUNNING', p_iics_run_id);
    COMMIT;
    reset_counters;
    RETURN l_id;
  END start_step;

  PROCEDURE end_step (p_step_log_id   IN NUMBER,
                      p_status        IN VARCHAR2 DEFAULT 'SUCCEEDED',
                      p_rows_read     IN NUMBER   DEFAULT NULL,
                      p_rows_written  IN NUMBER   DEFAULT NULL,
                      p_rows_rejected IN NUMBER   DEFAULT NULL,
                      p_message       IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE etl_step_log
       SET status        = p_status,
           rows_read     = COALESCE(p_rows_read,     g_rows_read),
           rows_written  = COALESCE(p_rows_written,  g_rows_written),
           rows_rejected = COALESCE(p_rows_rejected, g_rows_rejected),
           message       = SUBSTR(p_message, 1, 4000),
           end_ts        = SYSTIMESTAMP
     WHERE step_log_id = p_step_log_id;
    COMMIT;
  END end_step;

  PROCEDURE register_file (p_batch_id      IN NUMBER,
                           p_file_name     IN VARCHAR2,
                           p_expected_rows IN NUMBER,
                           p_md5           IN VARCHAR2,
                           p_status        IN VARCHAR2 DEFAULT 'VALIDATED') IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    MERGE INTO etl_file_audit t
    USING (SELECT p_batch_id b, p_file_name f FROM dual) s
       ON (t.batch_id = s.b AND t.file_name = s.f)
     WHEN MATCHED THEN UPDATE SET t.expected_rows = p_expected_rows,
                                  t.md5_checksum  = p_md5,
                                  t.status        = p_status,
                                  t.received_ts   = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (batch_id, file_name, expected_rows, md5_checksum, status)
                           VALUES (p_batch_id, p_file_name, p_expected_rows, p_md5, p_status);
    COMMIT;
  END register_file;

  PROCEDURE reset_counters IS
  BEGIN
    g_rows_read := NULL;
    g_rows_written := NULL;
    g_rows_rejected := NULL;
  END reset_counters;

END pkg_etl_control;
/
