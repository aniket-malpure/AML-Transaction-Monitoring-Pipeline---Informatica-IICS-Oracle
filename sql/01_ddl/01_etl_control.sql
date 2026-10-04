-- ============================================================================
-- 01_etl_control.sql   (run as AML_OWNER)
-- Batch / step control tables. The shell orchestrator and IICS taskflow both
-- write here, which is what makes a failed night restartable from the failed
-- step instead of rerunning the whole chain.
-- ============================================================================

CREATE SEQUENCE seq_etl_batch START WITH 1000 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_etl_step  START WITH 1    INCREMENT BY 1 CACHE 50;
CREATE SEQUENCE seq_etl_error START WITH 1    INCREMENT BY 1 CACHE 50;

CREATE TABLE etl_batch_run (
  batch_id         NUMBER         NOT NULL,
  business_date    DATE           NOT NULL,
  pipeline_name    VARCHAR2(60)   NOT NULL,
  status           VARCHAR2(20)   NOT NULL,
  run_mode         VARCHAR2(20)   DEFAULT 'IICS' NOT NULL,
  attempt_no       NUMBER(3)      DEFAULT 1 NOT NULL,
  start_ts         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  end_ts           TIMESTAMP,
  triggered_by     VARCHAR2(60)   DEFAULT SYS_CONTEXT('USERENV','OS_USER'),
  host_name        VARCHAR2(120)  DEFAULT SYS_CONTEXT('USERENV','HOST'),
  CONSTRAINT pk_etl_batch_run PRIMARY KEY (batch_id),
  CONSTRAINT ck_etl_batch_status CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','ABORTED')),
  CONSTRAINT ck_etl_batch_mode   CHECK (run_mode IN ('IICS','LOCAL'))
);

-- Only one RUNNING batch per pipeline and business date
CREATE UNIQUE INDEX ux_etl_batch_running
  ON etl_batch_run (CASE WHEN status = 'RUNNING' THEN pipeline_name END,
                    CASE WHEN status = 'RUNNING' THEN business_date END);

CREATE INDEX ix_etl_batch_bdate ON etl_batch_run (pipeline_name, business_date);

CREATE TABLE etl_step_log (
  step_log_id      NUMBER         NOT NULL,
  batch_id         NUMBER         NOT NULL,
  step_seq         NUMBER(4)      NOT NULL,
  step_name        VARCHAR2(80)   NOT NULL,
  step_type        VARCHAR2(20)   NOT NULL,
  status           VARCHAR2(20)   NOT NULL,
  rows_read        NUMBER,
  rows_written     NUMBER,
  rows_rejected    NUMBER,
  iics_run_id      VARCHAR2(60),
  message          VARCHAR2(4000),
  start_ts         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  end_ts           TIMESTAMP,
  CONSTRAINT pk_etl_step_log PRIMARY KEY (step_log_id),
  CONSTRAINT fk_etl_step_batch FOREIGN KEY (batch_id) REFERENCES etl_batch_run (batch_id),
  CONSTRAINT ck_etl_step_status CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','SKIPPED')),
  CONSTRAINT ck_etl_step_type   CHECK (step_type IN ('FILE_CHECK','IICS_TASK','SQLLDR','PLSQL','SHELL'))
);

CREATE INDEX ix_etl_step_batch ON etl_step_log (batch_id, step_name, status);

CREATE TABLE etl_file_audit (
  batch_id         NUMBER         NOT NULL,
  file_name        VARCHAR2(200)  NOT NULL,
  expected_rows    NUMBER,
  loaded_rows      NUMBER,
  md5_checksum     VARCHAR2(32),
  received_ts      TIMESTAMP      DEFAULT SYSTIMESTAMP,
  status           VARCHAR2(20)   NOT NULL,
  CONSTRAINT pk_etl_file_audit PRIMARY KEY (batch_id, file_name),
  CONSTRAINT fk_etl_file_batch FOREIGN KEY (batch_id) REFERENCES etl_batch_run (batch_id),
  CONSTRAINT ck_etl_file_status CHECK (status IN ('RECEIVED','VALIDATED','LOADED','REJECTED'))
);

CREATE TABLE etl_error_log (
  error_id         NUMBER         NOT NULL,
  batch_id         NUMBER,
  step_name        VARCHAR2(80),
  error_code       NUMBER,
  error_message    VARCHAR2(4000),
  error_backtrace  VARCHAR2(4000),
  record_key       VARCHAR2(200),
  logged_ts        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT pk_etl_error_log PRIMARY KEY (error_id)
);

CREATE INDEX ix_etl_error_batch ON etl_error_log (batch_id);

COMMENT ON TABLE etl_batch_run  IS 'One row per nightly AML pipeline attempt.';
COMMENT ON TABLE etl_step_log   IS 'Step-level audit; drives restart-from-failure.';
COMMENT ON TABLE etl_file_audit IS 'Inbound file reconciliation: control-file rows vs loaded rows.';
COMMENT ON TABLE etl_error_log  IS 'Autonomous-transaction error sink for PL/SQL and loaders.';
