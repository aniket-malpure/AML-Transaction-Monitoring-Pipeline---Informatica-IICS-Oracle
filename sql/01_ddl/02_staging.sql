-- ============================================================================
-- 02_staging.sql   (run as AML_OWNER)
-- Landing tables written by IICS mappings (or SQL*Loader in LOCAL mode).
-- Everything lands as VARCHAR2 so a bad value never kills the load; typing and
-- validation happen in PKG_LOAD_DW where rejects are logged, not lost.
-- Staging is truncated per batch, so NOLOGGING + no indexes keeps loads fast.
-- ============================================================================

CREATE TABLE stg_customer (
  batch_id           NUMBER,
  customer_id        VARCHAR2(20),
  customer_name      VARCHAR2(200),
  customer_type      VARCHAR2(20),
  date_of_birth      VARCHAR2(20),
  country_code       VARCHAR2(5),
  state_code         VARCHAR2(5),
  kyc_risk_rating    VARCHAR2(10),
  pep_flag           VARCHAR2(1),
  onboard_date       VARCHAR2(20),
  src_file_name      VARCHAR2(200),
  load_ts            TIMESTAMP DEFAULT SYSTIMESTAMP
) NOLOGGING;

CREATE TABLE stg_account (
  batch_id           NUMBER,
  account_id         VARCHAR2(20),
  customer_id        VARCHAR2(20),
  product_type       VARCHAR2(30),
  open_date          VARCHAR2(20),
  account_status     VARCHAR2(20),
  last_activity_date VARCHAR2(20),
  src_file_name      VARCHAR2(200),
  load_ts            TIMESTAMP DEFAULT SYSTIMESTAMP
) NOLOGGING;

CREATE TABLE stg_transaction (
  batch_id             NUMBER,
  txn_id               VARCHAR2(30),
  account_id           VARCHAR2(20),
  txn_ts               VARCHAR2(30),
  txn_type             VARCHAR2(20),
  channel              VARCHAR2(20),
  direction            VARCHAR2(2),
  amount               VARCHAR2(30),
  currency             VARCHAR2(3),
  counterparty_name    VARCHAR2(200),
  counterparty_country VARCHAR2(5),
  status               VARCHAR2(20),
  src_file_name        VARCHAR2(200),
  load_ts              TIMESTAMP DEFAULT SYSTIMESTAMP
) NOLOGGING;

CREATE TABLE stg_sanctions (
  batch_id           NUMBER,
  sdn_id             VARCHAR2(20),
  party_name         VARCHAR2(200),
  party_type         VARCHAR2(20),
  country_code       VARCHAR2(5),
  list_source        VARCHAR2(40),
  src_file_name      VARCHAR2(200),
  load_ts            TIMESTAMP DEFAULT SYSTIMESTAMP
) NOLOGGING;

CREATE TABLE stg_country_risk (
  batch_id           NUMBER,
  country_code       VARCHAR2(5),
  risk_tier          VARCHAR2(20),
  src_file_name      VARCHAR2(200),
  load_ts            TIMESTAMP DEFAULT SYSTIMESTAMP
) NOLOGGING;

-- Work table for the SCD2 customer load (rows vanish at commit)
CREATE GLOBAL TEMPORARY TABLE tmp_customer_delta (
  customer_id        VARCHAR2(20),
  customer_name      VARCHAR2(200),
  customer_type      VARCHAR2(20),
  date_of_birth      DATE,
  country_code       VARCHAR2(5),
  state_code         VARCHAR2(5),
  kyc_risk_rating    VARCHAR2(10),
  pep_flag           VARCHAR2(1),
  onboard_date       DATE,
  row_hash           VARCHAR2(64)
) ON COMMIT DELETE ROWS;
