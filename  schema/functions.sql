CREATE OR REPLACE FUNCTION create_user(
    p_nic VARCHAR,
    p_first_name VARCHAR,
    p_last_name VARCHAR,
    p_address VARCHAR,
    p_phone_number VARCHAR,
    p_username VARCHAR,
    p_hashed_password VARCHAR
)
RETURNS UUID AS
$$
DECLARE
    new_user_id UUID;
    new_activity_id UUID;
BEGIN
    BEGIN
        -- 1. Create activity log first
        INSERT INTO activity (logs)
        VALUES ('New user created')
        RETURNING activity_id INTO new_activity_id;

        -- 2. Insert into users (UUID auto)
        INSERT INTO users (
            nic, first_name, last_name, address, phone_number, activity_id
        )
        VALUES (
            p_nic, p_first_name, p_last_name, p_address, p_phone_number, new_activity_id
        )
        RETURNING user_id INTO new_user_id;

        -- 3. Insert into login (UUID auto)
        INSERT INTO user_login (
            user_id, username, password, password_last_update
        )
        VALUES (
            new_user_id, p_username, p_hashed_password, NOW()
        );

        RETURN new_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Error creating user: %', SQLERRM;
    END;
END;
$$ LANGUAGE plpgsql;






-- Add your other functions from  here