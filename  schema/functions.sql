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
    new_login_id UUID;
BEGIN
    -- Generate UUIDs
    new_user_id := gen_random_uuid();
    new_login_id := gen_random_uuid();

    -- Insert into users
    INSERT INTO users (
        user_id, nic, first_name, last_name, address, phone_number
    )
    VALUES (
        new_user_id, p_nic, p_first_name, p_last_name, p_address, p_phone_number
    );

    -- Insert into login
    INSERT INTO login (
        login_id, user_id, username, hashed_password, password_last_update
    )
    VALUES (
        new_login_id, new_user_id, p_username, p_hashed_password, NOW()
    );

    -- Return the new user_id
    RETURN new_user_id;
END;
$$ LANGUAGE plpgsql;








-- Second function here




