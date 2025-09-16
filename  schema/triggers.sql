-- when updating lo

CREATE OR REPLACE FUNCTION audit_user_login_update()
RETURNS TRIGGER AS $$
DECLARE
    changed_cols TEXT[];
BEGIN
    -- Get changed column names
    changed_cols := ARRAY(
        SELECT column_name
        FROM jsonb_object_keys(to_jsonb(OLD)) AS column_name
        WHERE to_jsonb(OLD)->column_name IS DISTINCT FROM to_jsonb(NEW)->column_name
    );

    -- Insert into audit_log
    INSERT INTO audit_log(
        table_name,
        record_id,
        action,
        old_values,
        changed_fields,
        user_id
    )
    VALUES(
        'user_login',
        OLD.login_id,
        'UPDATE',
        to_jsonb(OLD),
        changed_cols,
        NEW.updated_by  -- assuming updated_by stores current user
    );

    RETURN NEW; -- continue with the update
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER user_login_update_audit
BEFORE UPDATE ON user_login
FOR EACH ROW
EXECUTE FUNCTION audit_user_login_update();
