
CREATE FUNCTION public.audit_user_login_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- TOC entry 313 (class 1255 OID 30994)
-- Name: calculate_monthly_interest(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_monthly_interest() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_now TIMESTAMP := NOW();
BEGIN
    -- Step 1: Compute monthly interest into a temp table
    CREATE TEMP TABLE temp_monthly_interest AS
    WITH prev_month AS (
        SELECT 
            date_trunc('month', current_date) - interval '1 month' AS start_date,
            date_trunc('month', current_date) - interval '1 day' AS end_date
    ),
    days AS (
        SELECT generate_series(start_date::date, end_date::date, interval '1 day') AS day
        FROM prev_month
    ),
    tx AS (
        SELECT acc_id, type, amount, created_at::date AS tx_date, created_at
        FROM public.transactions
        WHERE created_at >= (SELECT start_date FROM prev_month)
          AND created_at <= (SELECT end_date FROM prev_month)
    ),
    daily_balances AS (
        SELECT
            a.acc_id,
            d.day,
            a.balance 
            - COALESCE(SUM(
                CASE 
                    WHEN t.type IN ('Deposit', 'BankTransfer-In') THEN t.amount
                    WHEN t.type IN ('Withdrawal', 'BankTransfer-Out') THEN -t.amount
                    ELSE 0
                END
            ), 0) AS opening_balance
        FROM public.account a
        CROSS JOIN days d
        LEFT JOIN tx t ON a.acc_id = t.acc_id AND t.tx_date = d.day
        WHERE a.status = 'active'  -- ✅ Only include active accounts
        GROUP BY a.acc_id, d.day, a.balance
    ),
    weighted_daily AS (
        SELECT
            db.acc_id,
            db.day,
            (
                db.opening_balance * 86400
                + COALESCE(SUM(
                    CASE 
                        WHEN t.type IN ('Deposit', 'BankTransfer-In') THEN EXTRACT(EPOCH FROM (t.created_at - db.day)) * t.amount
                        WHEN t.type IN ('Withdrawal', 'BankTransfer-Out') THEN EXTRACT(EPOCH FROM (t.created_at - db.day)) * -t.amount
                        ELSE 0
                    END
                ), 0)
            ) / 86400 AS avg_balance
        FROM daily_balances db
        LEFT JOIN tx t ON db.acc_id = t.acc_id AND t.tx_date = db.day
        GROUP BY db.acc_id, db.day, db.opening_balance
    )
    SELECT w.acc_id, SUM(GREATEST(w.avg_balance, 0) * sp.interest_rate / (100 * 365)) AS interest
    FROM weighted_daily w
    JOIN public.account a ON w.acc_id = a.acc_id
    JOIN public.savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
    WHERE a.status = 'active'  -- ✅ Again ensure only active accounts
    GROUP BY w.acc_id;

    -- Step 2: Insert interest transactions for active accounts only
    INSERT INTO public.transactions (amount, acc_id, type, description, created_at, created_by)
    SELECT interest, acc_id, 'Interest', 'Monthly interest', v_now, '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'
    FROM temp_monthly_interest
    WHERE interest > 0;  -- Optional: avoid inserting 0 interest

    -- Step 3: Update balances of active accounts only
    UPDATE public.account a
    SET balance = a.balance + tmi.interest
    FROM temp_monthly_interest tmi
    WHERE a.acc_id = tmi.acc_id
      AND a.status = 'active';  -- ✅ Only update active accounts

    -- Step 4: Drop temp table
    DROP TABLE temp_monthly_interest;

END;
$$;


--
-- TOC entry 306 (class 1255 OID 30995)
-- Name: calculate_transaction_totals(uuid, character varying, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_transaction_totals(p_acc_id uuid, p_period character varying, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS TABLE(summary_date date, year integer, month integer, total_deposits numeric, total_withdrawals numeric, total_transfers numeric, transaction_count bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF LOWER(p_period) = 'daily' THEN
        RETURN QUERY
        SELECT 
            DATE(t.created_at) as summary_date,
            NULL::INTEGER as year,
            NULL::INTEGER as month,
            COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) as total_deposits,
            COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) as total_withdrawals,
            COALESCE(SUM(CASE WHEN t.type IN ('BankTransfer-In', 'BankTransfer-Out') THEN t.amount ELSE 0 END), 0) as total_transfers,
            COUNT(t.transaction_id) as transaction_count
        FROM transactions t
        WHERE t.acc_id = p_acc_id
          AND (p_start_date IS NULL OR DATE(t.created_at) >= p_start_date)
          AND (p_end_date IS NULL OR DATE(t.created_at) <= p_end_date)
        GROUP BY DATE(t.created_at)
        ORDER BY DATE(t.created_at) DESC;
    ELSE
        -- Monthly summary
        RETURN QUERY
        SELECT 
            NULL::DATE as summary_date,
            EXTRACT(YEAR FROM t.created_at)::INTEGER as year,
            EXTRACT(MONTH FROM t.created_at)::INTEGER as month,
            COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) as total_deposits,
            COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) as total_withdrawals,
            COALESCE(SUM(CASE WHEN t.type IN ('BankTransfer-In', 'BankTransfer-Out') THEN t.amount ELSE 0 END), 0) as total_transfers,
            COUNT(t.transaction_id) as transaction_count
        FROM transactions t
        WHERE t.acc_id = p_acc_id
          AND (p_start_date IS NULL OR DATE(t.created_at) >= p_start_date)
          AND (p_end_date IS NULL OR DATE(t.created_at) <= p_end_date)
        GROUP BY EXTRACT(YEAR FROM t.created_at), EXTRACT(MONTH FROM t.created_at)
        ORDER BY year DESC, month DESC;
    END IF;
END;
$$;


--
-- TOC entry 296 (class 1255 OID 30996)
-- Name: cleanup_expired_user_refresh_tokens(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_expired_user_refresh_tokens() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM user_refresh_tokens WHERE expires_at < CURRENT_TIMESTAMP;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;


--
-- TOC entry 323 (class 1255 OID 30997)
-- Name: create_account_for_existing_customer_by_nic(character varying, uuid, uuid, uuid, numeric, public.account_status); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_account_for_existing_customer_by_nic(p_nic character varying, p_branch_id uuid, p_savings_plan_id uuid, p_created_by_user_id uuid, p_balance numeric DEFAULT 0.00, p_status public.account_status DEFAULT 'active'::public.account_status) RETURNS TABLE(acc_id uuid, account_no character varying, customer_id uuid)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_customer_id UUID;
    v_acc_id UUID;
    v_account_no VARCHAR(20);
BEGIN
    -- Find customer_id by NIC
    SELECT c.customer_id INTO v_customer_id
    FROM customer c
    WHERE c.nic = p_nic;

    -- Check if customer exists
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Customer not found with NIC: %', p_nic;
    END IF;

    -- Insert new account (account_no is auto-generated)
    INSERT INTO account (
        branch_id, 
        savings_plan_id, 
        balance, 
        status, 
        created_by, 
        updated_by
    ) VALUES (
        p_branch_id,
        p_savings_plan_id,
        p_balance,
        p_status,
        p_created_by_user_id,
        p_created_by_user_id
    )
    RETURNING account.acc_id, account.account_no INTO v_acc_id, v_account_no;

    -- Link customer and account
    INSERT INTO accounts_owner (acc_id, customer_id)
    VALUES (v_acc_id, v_customer_id);

    -- Return the results
    RETURN QUERY SELECT v_acc_id, v_account_no, v_customer_id;
END;
$$;


--
-- TOC entry 282 (class 1255 OID 30998)
-- Name: create_branch(character varying, character varying, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_branch(p_name character varying, p_address character varying, p_created_by uuid) RETURNS TABLE(branch_id uuid, name character varying, address character varying, created_at timestamp without time zone, updated_at timestamp without time zone, created_by uuid, updated_by uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Check if branch with same name already exists
    IF EXISTS (SELECT 1 FROM branch WHERE LOWER(TRIM(branch.name)) = LOWER(TRIM(p_name))) THEN
        RAISE EXCEPTION 'Branch with name "%" already exists', p_name;
    END IF;
    
    -- Validate input
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RAISE EXCEPTION 'Branch name cannot be empty';
    END IF;
    
    IF p_address IS NULL OR TRIM(p_address) = '' THEN
        RAISE EXCEPTION 'Branch address cannot be empty';
    END IF;
    
    -- Insert new branch and return the result
    RETURN QUERY
    INSERT INTO branch (name, address, created_by, updated_by)
    VALUES (TRIM(p_name), TRIM(p_address), p_created_by, p_created_by)
    RETURNING 
        branch.branch_id,
        branch.name,
        branch.address,
        branch.created_at,
        branch.updated_at,
        branch.created_by,
        branch.updated_by;
END;
$$;


--
-- TOC entry 281 (class 1255 OID 30999)
-- Name: create_customer_with_login(text, text, text, text, date, text, text, uuid, uuid, numeric, uuid, public.account_status); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_customer_with_login(p_full_name text, p_address text, p_phone_number text, p_nic text, p_dob date, p_username text, p_password text, p_branch_id uuid, p_savings_plan_id uuid, p_balance numeric, p_created_by uuid, p_status public.account_status DEFAULT 'active'::public.account_status) RETURNS TABLE(customer_id uuid, account_no text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_customer_id UUID;
    v_account_id UUID;
    v_account_no TEXT;
BEGIN
    -- Insert account
    INSERT INTO account (
        branch_id, savings_plan_id, balance, status, created_by, updated_by
    ) VALUES (
        p_branch_id, p_savings_plan_id, p_balance, COALESCE(p_status, 'active'), p_created_by, p_created_by
    )
    RETURNING account.acc_id, account.account_no INTO v_account_id, v_account_no;

    -- Insert customer
    INSERT INTO customer (
        full_name, address, phone_number, nic, dob, created_by, updated_by
    ) VALUES (
        p_full_name, p_address, p_phone_number, p_nic, p_dob, p_created_by, p_created_by
    )
    RETURNING customer.customer_id INTO v_customer_id;

    -- Link account and customer
    INSERT INTO accounts_owner (acc_id, customer_id)
    VALUES (v_account_id, v_customer_id);

    -- Insert customer login (password passed in already hashed from Python)
    INSERT INTO customer_login (
        customer_id, username, password, created_by, updated_by
    ) VALUES (
        v_customer_id, p_username, p_password, p_created_by, p_created_by
    );

    RETURN QUERY SELECT v_customer_id, v_account_no;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Error: %', SQLERRM;
        RAISE;
END;
$$;


--
-- TOC entry 318 (class 1255 OID 31000)
-- Name: create_fd_plan(integer, numeric, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_fd_plan(p_duration integer, p_interest numeric, p_created_by uuid) RETURNS TABLE(fd_plan_id uuid, duration integer, interest_rate numeric, status text, created_at timestamp without time zone, updated_at timestamp without time zone, created_by uuid, updated_by uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    INSERT INTO fd_plan (duration, interest_rate, status, created_by, updated_by)
    VALUES (p_duration, p_interest, 'active', p_created_by, p_created_by)
    RETURNING fd_plan.fd_plan_id,
              fd_plan.duration,
              fd_plan.interest_rate,
              fd_plan.status::TEXT,
              fd_plan.created_at,
              fd_plan.updated_at,
              fd_plan.created_by,
              fd_plan.updated_by;
END;
$$;


--
-- TOC entry 278 (class 1255 OID 31481)
-- Name: create_fixed_deposit(uuid, numeric, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_fixed_deposit(p_acc_id uuid, p_amount numeric, p_fd_plan_id uuid, p_created_by uuid) RETURNS TABLE(fd_id uuid, fd_account_no bigint, balance numeric, acc_id uuid, opened_date timestamp without time zone, maturity_date timestamp without time zone, fd_plan_id uuid, created_at timestamp without time zone, updated_at timestamp without time zone, status public.status_enum, created_by uuid, updated_by uuid)
    LANGUAGE plpgsql
    AS $$
DECLARE
    plan_duration INT;
    new_fd fixed_deposit%ROWTYPE;
BEGIN
    -- Fetch the FD plan duration
    SELECT duration INTO plan_duration
FROM fd_plan
WHERE fd_plan.fd_plan_id = p_fd_plan_id;


    IF plan_duration IS NULL THEN
        RAISE EXCEPTION 'Invalid FD plan ID: %', p_fd_plan_id;
    END IF;

    -- Insert new fixed deposit and capture inserted row
    INSERT INTO fixed_deposit (
        balance,
        acc_id,
        fd_plan_id,
        maturity_date,
        status,
        created_by,
        updated_by
    )
    VALUES (
        p_amount,
        p_acc_id,
        p_fd_plan_id,
        CURRENT_TIMESTAMP + (plan_duration || ' months')::INTERVAL,
        'active',
        p_created_by,
        p_created_by
    )
    RETURNING *
    INTO new_fd;

    -- Insert corresponding transaction
    INSERT INTO transactions(
        amount,
        acc_id,
        type,
        description,
        created_by
    )
    VALUES (
        p_amount,
        p_acc_id,
        'Deposit',
        'Created fixed deposit',
        p_created_by
    );

    -- Return the inserted FD row
    RETURN QUERY SELECT 
        new_fd.fd_id,
        new_fd.fd_account_no,
        new_fd.balance,
        new_fd.acc_id,
        new_fd.opened_date,
        new_fd.maturity_date,
        new_fd.fd_plan_id,
        new_fd.created_at,
        new_fd.updated_at,
        new_fd.status,
        new_fd.created_by,
        new_fd.updated_by;
END;
$$;


--
-- TOC entry 317 (class 1255 OID 31002)
-- Name: create_initial_user(character varying, character varying, character varying, character varying, character varying, date, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_initial_user(p_nic character varying, p_first_name character varying, p_last_name character varying, p_address character varying, p_phone_number character varying, p_dob date, p_username character varying, p_password_hash text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_user_id UUID;
BEGIN
    -- Insert into users table (without created_by for first admin)
    INSERT INTO users (
        nic, first_name, last_name, address, phone_number, dob
    ) VALUES (
        p_nic, p_first_name, p_last_name, p_address, p_phone_number, p_dob
    ) RETURNING user_id INTO new_user_id;

    -- Insert into user_login table
    INSERT INTO user_login (
        user_id, username, password
    ) VALUES (
        new_user_id, p_username, p_password_hash
    );

    -- Return the new user_id
    RETURN new_user_id;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE;
END;
$$;


--
-- TOC entry 309 (class 1255 OID 31477)
-- Name: create_savings_plan(character varying, numeric, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_savings_plan(p_plan_name character varying, p_interest_rate numeric, p_user_id uuid, p_minimum_balance numeric) RETURNS TABLE(savings_plan_id uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    INSERT INTO savings_plan (plan_name, interest_rate, created_by, updated_by, minimum_balance)
    VALUES (p_plan_name, p_interest_rate, p_user_id, p_user_id, p_minimum_balance)
    RETURNING savings_plan.savings_plan_id;
END;
$$;


--
-- TOC entry 293 (class 1255 OID 31004)
-- Name: create_user(character varying, character varying, character varying, character varying, character varying, date, character varying, character varying, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_user(p_nic character varying, p_first_name character varying, p_last_name character varying, p_address character varying, p_phone_number character varying, p_dob date, p_username character varying, p_hashed_password character varying, p_created_by uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_user_id UUID;
BEGIN
    -- 1. Insert into users table
    INSERT INTO users (
        nic, first_name, last_name, address, phone_number, dob, created_by
    )
    VALUES (
        p_nic, p_first_name, p_last_name, p_address, p_phone_number, p_dob, p_created_by
    )
    RETURNING user_id INTO new_user_id;

    -- 2. Insert into user_login table
    INSERT INTO user_login (
        user_id, username, password, password_last_update
    )
    VALUES (
        new_user_id, p_username, p_hashed_password, NOW()
    );

    -- 3. Log to audit_log
    INSERT INTO audit_log (
        table_name,
        record_id,
        action,
        old_values,
        changed_fields,
        user_id
    )
    VALUES (
        'users',
        new_user_id,
        'INSERT',
        NULL,
        ARRAY['nic','first_name','last_name','address','phone_number','dob','created_by'],
        p_created_by
    );

    -- 4. Return the new user's UUID
    RETURN new_user_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error creating user: %', SQLERRM;
END;
$$;
