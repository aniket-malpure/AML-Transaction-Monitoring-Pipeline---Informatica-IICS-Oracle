-- ============================================================================
-- uninstall.sql   (run as AML_OWNER) - drops every project object.
-- DEV/CI ONLY: this destroys alert history.
-- ============================================================================
SET SERVEROUTPUT ON
BEGIN
  FOR o IN (SELECT object_name, object_type
              FROM user_objects
             WHERE object_type IN ('VIEW','PACKAGE','TRIGGER','SEQUENCE','TABLE')
               AND object_name NOT LIKE 'BIN$%'
             ORDER BY DECODE(object_type, 'VIEW', 1, 'TRIGGER', 2, 'PACKAGE', 3, 'SEQUENCE', 4, 'TABLE', 5))
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "' || o.object_name || '"'
                        || CASE WHEN o.object_type = 'TABLE' THEN ' CASCADE CONSTRAINTS PURGE' END;
      DBMS_OUTPUT.PUT_LINE('dropped ' || o.object_type || ' ' || o.object_name);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('skip ' || o.object_type || ' ' || o.object_name || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/
