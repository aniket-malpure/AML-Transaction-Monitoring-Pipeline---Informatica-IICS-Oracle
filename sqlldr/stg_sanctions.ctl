-- SQL*Loader control file for STG_SANCTIONS (LOCAL run mode).
-- Template: run_aml_batch.sh replaces __BATCH_ID__ and __DATA_FILE__ per run.
-- TRUNCATE makes a rerun of this step safe; errors go to the .bad file.
OPTIONS (SKIP=1, ERRORS=100000, ROWS=5000, BINDSIZE=20971520)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE '__DATA_FILE__'
TRUNCATE
INTO TABLE STG_SANCTIONS
FIELDS TERMINATED BY '|' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
  SDN_ID,
  PARTY_NAME             CHAR(200),
  PARTY_TYPE,
  COUNTRY_CODE,
  LIST_SOURCE,
  BATCH_ID               CONSTANT "__BATCH_ID__",
  SRC_FILE_NAME          CONSTANT "__FILE_NAME__",
  LOAD_TS                SYSDATE
)
