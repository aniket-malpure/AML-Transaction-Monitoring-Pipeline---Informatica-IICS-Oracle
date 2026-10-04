-- ============================================================================
-- 00_create_schema_owner.sql
-- Run once as SYSTEM (or another DBA account) inside the pluggable database.
--   sqlplus system/<pwd>@//localhost:1521/FREEPDB1 @00_create_schema_owner.sql
-- Creates the AML schema owner plus a read-only role used by analysts/reports.
-- ============================================================================
WHENEVER SQLERROR EXIT FAILURE

DEFINE aml_user = AML_OWNER
DEFINE aml_pwd  = "&1"

PROMPT Creating schema owner &aml_user ...

DECLARE
  l_cnt PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_cnt FROM dba_users WHERE username = '&aml_user';
  IF l_cnt = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER &aml_user IDENTIFIED BY "&aml_pwd" '
                   || 'DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS';
  END IF;

  SELECT COUNT(*) INTO l_cnt FROM dba_roles WHERE role = 'AML_READ_ROLE';
  IF l_cnt = 0 THEN
    EXECUTE IMMEDIATE 'CREATE ROLE AML_READ_ROLE';
  END IF;
END;
/

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TRIGGER, CREATE TYPE, CREATE SYNONYM,
      CREATE JOB TO &aml_user;

-- External tables / SQL*Loader direct path read the inbound landing directory
GRANT CREATE ANY DIRECTORY TO &aml_user;

-- UTL_MATCH (Jaro-Winkler / edit distance) is used for sanctions name screening
GRANT EXECUTE ON SYS.UTL_MATCH TO &aml_user;

PROMPT Done.
