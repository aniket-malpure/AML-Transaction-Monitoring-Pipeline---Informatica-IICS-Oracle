-- ============================================================================
-- install.sql   (run as AML_OWNER from the repository root)
--   sqlplus aml_owner/<pwd>@//localhost:1521/FREEPDB1 @sql/install.sql
-- Creates every object in dependency order. Safe to run on an empty schema;
-- use uninstall.sql first to rebuild from scratch.
-- ============================================================================
SET ECHO OFF
SET FEEDBACK ON
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT == DDL ==
@@01_ddl/01_etl_control.sql
@@01_ddl/02_staging.sql
@@01_ddl/03_star_schema.sql
@@01_ddl/04_triggers.sql
@@01_ddl/05_seed_reference_data.sql

PROMPT == PL/SQL packages ==
@@02_plsql/01_pkg_aml_util.sql
@@02_plsql/02_pkg_etl_control.sql
@@02_plsql/03_pkg_load_dw.sql
@@02_plsql/04_pkg_aml_rules.sql
@@02_plsql/05_views.sql

PROMPT == Compile check ==
SET SERVEROUTPUT ON
DECLARE
  l_invalid PLS_INTEGER;
BEGIN
  DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE);
  SELECT COUNT(*) INTO l_invalid FROM user_objects WHERE status = 'INVALID';
  IF l_invalid > 0 THEN
    FOR o IN (SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID') LOOP
      DBMS_OUTPUT.PUT_LINE('INVALID: ' || o.object_type || ' ' || o.object_name);
    END LOOP;
    RAISE_APPLICATION_ERROR(-20000, l_invalid || ' invalid object(s) after install');
  END IF;
  DBMS_OUTPUT.PUT_LINE('All objects valid.');
END;
/
PROMPT Install complete.
