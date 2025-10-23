--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

-- Started on 2025-10-23 12:06:53 +0530

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 3 (class 3079 OID 31407)
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;


--
-- TOC entry 3813 (class 0 OID 0)
-- Dependencies: 3
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL';


--
-- TOC entry 7 (class 2615 OID 30441)
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- TOC entry 3814 (class 0 OID 0)
-- Dependencies: 7
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- TOC entry 2 (class 3079 OID 30923)
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- TOC entry 3815 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- TOC entry 962 (class 1247 OID 30961)
-- Name: account_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.account_status AS ENUM (
    'active',
    'frozen',
    'closed'
);


--
-- TOC entry 965 (class 1247 OID 30968)
-- Name: audit_action; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.audit_action AS ENUM (
    'INSERT',
    'UPDATE',
    'DELETE'
);


--
-- TOC entry 968 (class 1247 OID 30976)
-- Name: status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.status_enum AS ENUM (
    'active',
    'inactive'
);


--
-- TOC entry 971 (class 1247 OID 30982)
-- Name: transaction_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.transaction_type AS ENUM (
    'Deposit',
    'Withdrawal',
    'Interest',
    'BankTransfer-In',
    'BankTransfer-Out'
);


--
-- TOC entry 264 (class 1255 OID 30993)
-- Name: audit_user_login_update(); Type: FUNCTION; Schema: public; Owner: -
--

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
-- TOC entry 327 (class 1255 OID 30994)
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
-- TOC entry 319 (class 1255 OID 30995)
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
-- TOC entry 309 (class 1255 OID 30996)
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
-- TOC entry 338 (class 1255 OID 30997)
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
-- TOC entry 295 (class 1255 OID 30998)
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
-- TOC entry 294 (class 1255 OID 30999)
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
-- TOC entry 332 (class 1255 OID 31000)
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
-- TOC entry 322 (class 1255 OID 31492)
-- Name: create_fd_plan(integer, numeric, bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_fd_plan(p_duration integer, p_interest numeric, p_min_amount bigint, p_created_by uuid) RETURNS TABLE(fd_plan_id uuid, duration integer, interest_rate numeric, min_amount bigint, status text, created_at timestamp without time zone, updated_at timestamp without time zone, created_by uuid, updated_by uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    INSERT INTO fd_plan (duration, interest_rate, min_amount, status, created_by, updated_by)
    VALUES (p_duration, p_interest, p_min_amount, 'active', p_created_by, p_created_by)
    RETURNING fd_plan.fd_plan_id,
              fd_plan.duration,
              fd_plan.interest_rate,
              fd_plan.min_amount,
              fd_plan.status::TEXT,
              fd_plan.created_at,
              fd_plan.updated_at,
              fd_plan.created_by,
              fd_plan.updated_by;
END;
$$;


--
-- TOC entry 291 (class 1255 OID 31481)
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
        updated_by,
		next_interest_day
    )
    VALUES (
        p_amount,
        p_acc_id,
        p_fd_plan_id,
        CURRENT_TIMESTAMP + (plan_duration || ' months')::INTERVAL,
        'active',
        p_created_by,
        p_created_by,
		CURRENT_DATE + INTERVAL '30 days'
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
-- TOC entry 331 (class 1255 OID 31002)
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
-- TOC entry 323 (class 1255 OID 31477)
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
-- TOC entry 306 (class 1255 OID 31004)
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


--
-- TOC entry 311 (class 1255 OID 31005)
-- Name: create_user(character varying, character varying, character varying, character varying, character varying, date, character varying, character varying, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_user(p_nic character varying, p_first_name character varying, p_last_name character varying, p_address character varying, p_phone_number character varying, p_dob date, p_username character varying, p_hashed_password character varying, p_created_by uuid, p_updated_by uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_user_id UUID;
BEGIN
    -- 1. Insert into users table
    INSERT INTO users (
        nic, first_name, last_name, address, phone_number, dob, created_by, updated_by
    )
    VALUES (
        p_nic, p_first_name, p_last_name, p_address, p_phone_number, p_dob, p_created_by, p_updated_by
    )
    RETURNING user_id INTO new_user_id;

    -- 2. Insert into user_login table
    INSERT INTO user_login (
        user_id, username, password, password_last_update, created_by, updated_by
    )
    VALUES (
        new_user_id, p_username, p_hashed_password, NOW(), p_created_by, p_updated_by
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


--
-- TOC entry 337 (class 1255 OID 31490)
-- Name: daily_fd_interest_check(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.daily_fd_interest_check() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM process_fd_interest_payment();
    
    RAISE NOTICE 'Daily FD interest check completed at %', CURRENT_TIMESTAMP;
END;
$$;


--
-- TOC entry 287 (class 1255 OID 31006)
-- Name: get_account_transactions_by_uuid(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_account_transactions_by_uuid(p_account_id uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(transaction_id uuid, amount numeric, acc_id uuid, type character varying, description text, reference_no bigint, created_at timestamp without time zone, created_by uuid, account_no bigint, account_holder_name character varying, branch_name character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Validate that account exists
    IF NOT EXISTS (SELECT 1 FROM account WHERE acc_id = p_account_id) THEN
        RAISE EXCEPTION 'Account with UUID % not found', p_account_id;
    END IF;
    
    -- Return paginated transaction history with account details
    RETURN QUERY
    SELECT 
        t.transaction_id,
        t.amount,
        t.acc_id,
        t.type,
        t.description,
        t.reference_no,
        t.created_at,
        t.created_by,
        a.account_no,
        c.full_name as account_holder_name,
        b.branch_name
    FROM transactions t
    JOIN account a ON t.acc_id = a.acc_id
    LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
    LEFT JOIN customer c ON ao.customer_id = c.customer_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    WHERE 
        t.acc_id = p_account_id
    ORDER BY t.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;


--
-- TOC entry 263 (class 1255 OID 31007)
-- Name: get_all_transactions_with_account_details(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_all_transactions_with_account_details(p_limit integer, p_offset integer) RETURNS TABLE(transaction_id uuid, amount numeric, acc_id uuid, type character varying, description text, reference_no character varying, created_at timestamp without time zone, created_by uuid, acc_holder_name character varying, branch_id uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.transaction_id, 
        t.amount, 
        t.acc_id, 
        t.type::VARCHAR,          -- cast enum to varchar
        t.description, 
        t.reference_no::VARCHAR,  -- cast bigint to varchar
        t.created_at, 
        t.created_by,
        c.full_name as acc_holder_name, 
        a.branch_id
    FROM transactions t
    LEFT JOIN account a ON t.acc_id = a.acc_id
    LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
    LEFT JOIN customer c ON ao.customer_id = c.customer_id
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;


--
-- TOC entry 296 (class 1255 OID 31463)
-- Name: get_branch_transaction_report(uuid, date, date, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_branch_transaction_report(p_branch_id uuid, p_start_date date, p_end_date date, p_transaction_type character varying DEFAULT NULL::character varying) RETURNS TABLE(branch_id uuid, branch_name character varying, total_deposits numeric, total_withdrawals numeric, total_transfers_in numeric, total_transfers_out numeric, transaction_count bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        b.branch_id,
        b.name AS branch_name,
        COALESCE(SUM(CASE WHEN t.type = 'Deposit' THEN t.amount ELSE 0 END), 0) AS total_deposits,
        COALESCE(SUM(CASE WHEN t.type = 'Withdrawal' THEN t.amount ELSE 0 END), 0) AS total_withdrawals,
        COALESCE(SUM(CASE WHEN t.type = 'BankTransfer-In' THEN t.amount ELSE 0 END), 0) AS total_transfers_in,
        COALESCE(SUM(CASE WHEN t.type = 'BankTransfer-Out' THEN t.amount ELSE 0 END), 0) AS total_transfers_out,
        COUNT(t.transaction_id)::bigint AS transaction_count
    FROM branch b
    LEFT JOIN account a ON b.branch_id = a.branch_id
    LEFT JOIN transactions t ON a.acc_id = t.acc_id 
        AND DATE(t.created_at) BETWEEN p_start_date AND p_end_date
        AND (p_transaction_type IS NULL OR t.type = p_transaction_type::transaction_type)
    WHERE b.branch_id = p_branch_id
    GROUP BY b.branch_id, b.name;
END;
$$;


--
-- TOC entry 261 (class 1255 OID 31009)
-- Name: get_fd_by_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_fd_by_id(p_fd_id uuid) RETURNS TABLE(fd_id uuid, fd_account_no bigint, balance numeric, acc_id uuid, opened_date timestamp without time zone, maturity_date timestamp without time zone, fd_plan_id uuid, fd_created_at timestamp without time zone, fd_updated_at timestamp without time zone, account_no bigint, branch_name character varying, plan_duration integer, plan_interest_rate numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        fd.fd_id,
        fd.fd_account_no,
        fd.balance,
        fd.acc_id,
        fd.opened_date,
        fd.maturity_date,
        fd.fd_plan_id,
        fd.created_at AS fd_created_at,
        fd.updated_at AS fd_updated_at,
        a.account_no,
        b.name AS branch_name,
        fp.duration AS plan_duration,
        fp.interest_rate AS plan_interest_rate
    FROM fixed_deposit fd
    LEFT JOIN account a ON fd.acc_id = a.acc_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
    WHERE fd.fd_id = p_fd_id;
END;
$$;


--
-- TOC entry 298 (class 1255 OID 31010)
-- Name: get_fixed_deposit_by_fd_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_fixed_deposit_by_fd_id(p_fd_id uuid) RETURNS TABLE(fd_id uuid, fd_account_no bigint, balance numeric, acc_id uuid, opened_date timestamp without time zone, maturity_date timestamp without time zone, fd_plan_id uuid, fd_created_at timestamp without time zone, fd_updated_at timestamp without time zone, account_no bigint, branch_name character varying, plan_duration integer, plan_interest_rate numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        fd.fd_id,
        fd.fd_account_no,
        fd.balance,
        fd.acc_id,
        fd.opened_date,
        fd.maturity_date,
        fd.fd_plan_id,
        fd.created_at AS fd_created_at,
        fd.updated_at AS fd_updated_at,
        a.account_no,
        b.name AS branch_name,
        fp.duration AS plan_duration,
        fp.interest_rate AS plan_interest_rate
    FROM fixed_deposit fd
    LEFT JOIN account a ON fd.acc_id = a.acc_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
    WHERE fd.fd_id = p_fd_id;
END;
$$;


--
-- TOC entry 329 (class 1255 OID 31011)
-- Name: get_fixed_deposit_with_details(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_fixed_deposit_with_details(p_fd_id uuid) RETURNS TABLE(fd_id uuid, fd_account_no bigint, balance numeric, acc_id uuid, opened_date timestamp without time zone, maturity_date timestamp without time zone, fd_plan_id uuid, fd_created_at timestamp without time zone, fd_updated_at timestamp without time zone, account_no bigint, branch_name character varying, plan_duration integer, plan_interest_rate numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        fd.fd_id,
        fd.fd_account_no,
        fd.balance,
        fd.acc_id,
        fd.opened_date,
        fd.maturity_date,
        fd.fd_plan_id,
        fd.created_at,
        fd.updated_at,
        a.account_no,
        b.name as branch_name,
        fp.duration as plan_duration,
        fp.interest_rate as plan_interest_rate
    FROM fixed_deposit fd
    LEFT JOIN account a ON fd.acc_id = a.acc_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
    WHERE fd.fd_id = p_fd_id;
END;
$$;


--
-- TOC entry 333 (class 1255 OID 31012)
-- Name: get_fixed_deposits_by_customer_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_fixed_deposits_by_customer_id(p_customer_id uuid) RETURNS TABLE(fd_id uuid, fd_account_no bigint, balance numeric, acc_id uuid, opened_date timestamp without time zone, maturity_date timestamp without time zone, fd_plan_id uuid, fd_created_at timestamp without time zone, fd_updated_at timestamp without time zone, account_no bigint, branch_name character varying, plan_duration integer, plan_interest_rate numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        fd.fd_id,
        fd.fd_account_no,
        fd.balance,
        fd.acc_id,
        fd.opened_date,
        fd.maturity_date,
        fd.fd_plan_id,
        fd.created_at AS fd_created_at,
        fd.updated_at AS fd_updated_at,
        a.account_no,
        b.name AS branch_name,
        fp.duration AS plan_duration,
        fp.interest_rate AS plan_interest_rate
    FROM fixed_deposit fd
    LEFT JOIN account a ON fd.acc_id = a.acc_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
    LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
    WHERE ao.customer_id = p_customer_id
    ORDER BY fd.opened_date DESC;
END;
$$;


--
-- TOC entry 341 (class 1255 OID 31013)
-- Name: get_fixed_deposits_by_savings_account(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_fixed_deposits_by_savings_account(p_account_no bigint) RETURNS TABLE(fd_id uuid, fd_account_no bigint, balance numeric, acc_id uuid, opened_date timestamp without time zone, maturity_date timestamp without time zone, fd_plan_id uuid, fd_created_at timestamp without time zone, fd_updated_at timestamp without time zone, account_no bigint, branch_name character varying, plan_duration integer, plan_interest_rate numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        fd.fd_id,
        fd.fd_account_no,
        fd.balance,
        fd.acc_id,
        fd.opened_date,
        fd.maturity_date,
        fd.fd_plan_id,
        fd.created_at AS fd_created_at,
        fd.updated_at AS fd_updated_at,
        a.account_no,
        b.name AS branch_name,
        fp.duration AS plan_duration,
        fp.interest_rate AS plan_interest_rate
    FROM fixed_deposit fd
    LEFT JOIN account a ON fd.acc_id = a.acc_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
    WHERE a.account_no = p_account_no
    ORDER BY fd.opened_date DESC;
END;
$$;


--
-- TOC entry 277 (class 1255 OID 31014)
-- Name: get_transaction_history_by_account(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_transaction_history_by_account(p_acc_id uuid, p_limit integer, p_offset integer) RETURNS TABLE(transaction_id uuid, amount numeric, acc_id uuid, type public.transaction_type, description text, reference_no bigint, created_at timestamp without time zone, created_by uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.transaction_id, 
        t.amount, 
        t.acc_id, 
        t.type, 
        t.description, 
        t.reference_no, 
        t.created_at, 
        t.created_by
    FROM transactions t
    WHERE t.acc_id = p_acc_id
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;


--
-- TOC entry 297 (class 1255 OID 31478)
-- Name: get_transaction_history_by_date_range(date, date, uuid, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_transaction_history_by_date_range(p_start_date date, p_end_date date, p_acc_id uuid DEFAULT NULL::uuid, p_transaction_type character varying DEFAULT NULL::character varying) RETURNS TABLE(transaction_id uuid, amount numeric, acc_id uuid, type public.transaction_type, description text, reference_no bigint, created_at timestamp without time zone, created_by uuid, account_no bigint, account_holder_name character varying, branch_name character varying, username character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.transaction_id,
        t.amount,
        t.acc_id,
        t.type,
        t.description,
        t.reference_no,
        t.created_at,
        t.created_by,
        a.account_no,
        c.full_name as account_holder_name,
        b.name as branch_name,
        ul.username AS username  -- ✅ Matches 12th column
    FROM transactions t
    JOIN account a ON t.acc_id = a.acc_id
    LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
    LEFT JOIN customer c ON ao.customer_id = c.customer_id
    LEFT JOIN branch b ON a.branch_id = b.branch_id
    LEFT JOIN user_login ul ON t.created_by = ul.user_id
    WHERE 
        DATE(t.created_at) >= p_start_date
        AND DATE(t.created_at) <= p_end_date
        AND (p_acc_id IS NULL OR t.acc_id = p_acc_id)
        AND (p_transaction_type IS NULL OR t.type = p_transaction_type::transaction_type)
    ORDER BY t.created_at DESC;
END;
$$;


--
-- TOC entry 307 (class 1255 OID 31016)
-- Name: process_deposit_transaction(uuid, numeric, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_deposit_transaction(p_acc_id uuid, p_amount numeric, p_description text, p_created_by uuid) RETURNS TABLE(transaction_id uuid, reference_no bigint, new_balance numeric, success boolean, error_message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    current_balance NUMERIC;
    updated_balance NUMERIC;
BEGIN
    -- Check account exists and get current balance
    SELECT balance INTO current_balance FROM account WHERE acc_id = p_acc_id;

    IF current_balance IS NULL THEN
        RETURN QUERY
        SELECT NULL::UUID, NULL::BIGINT, 0::NUMERIC, FALSE, 'Account not found';
        RETURN;
    END IF;

    -- Calculate updated balance
    updated_balance := current_balance + p_amount;

    -- Insert transaction record (DB auto-generates IDs)
    INSERT INTO transactions (amount, acc_id, type, description, created_at, created_by)
    VALUES (p_amount, p_acc_id, 'Deposit', p_description, NOW(), p_created_by)
    RETURNING transactions.transaction_id, transactions.reference_no
    INTO transaction_id, reference_no;

    -- Update account balance
    UPDATE account SET balance = updated_balance WHERE acc_id = p_acc_id;

    RETURN QUERY
    SELECT transaction_id, reference_no, updated_balance, TRUE, NULL;

EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY
        SELECT NULL::UUID, NULL::BIGINT, current_balance, FALSE, SQLERRM;
END;
$$;


--
-- TOC entry 273 (class 1255 OID 31489)
-- Name: process_fd_interest_payment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_fd_interest_payment() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    fd_record RECORD;
    interest_amount NUMERIC(24, 12);
    daily_rate NUMERIC(24, 12);
BEGIN
    -- Loop through all active FDs where today matches next_interest_day
    FOR fd_record IN 
        SELECT 
            fd.fd_id,
            fd.balance,
            fd.acc_id,
            fd.fd_plan_id,
            fd.next_interest_day,
            fd.fd_account_no,
            fp.interest_rate,
            a.account_no,
            a.balance as account_balance
        FROM 
            public.fixed_deposit fd
        INNER JOIN 
            public.fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
        INNER JOIN 
            public.account a ON fd.acc_id = a.acc_id
        WHERE 
            fd.status = 'active'
            AND fp.status = 'active'
            AND a.status = 'active'
            AND fd.next_interest_day = CURRENT_DATE
    LOOP
        -- Calculate daily interest rate (annual rate / 365)
        daily_rate := fd_record.interest_rate / 365.0 / 100.0;
        
        -- Calculate interest for 30 days
        interest_amount := fd_record.balance * daily_rate * 30;
        
        -- Round to 2 decimal places for transaction
        interest_amount := ROUND(interest_amount, 2);
        
        -- Insert interest transaction
        INSERT INTO public.transactions (
            amount,
            acc_id,
            type,
            description,
            created_at,
            created_by
        ) VALUES (
            interest_amount,
            fd_record.acc_id,
            'Deposit',
            'FD Interest - FD Account No: ' || fd_record.fd_account_no,
            CURRENT_TIMESTAMP,
            '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'  -- System generated, so created_by is NULL
        );
        
        -- Update the linked savings account balance
        UPDATE public.account
        SET 
            balance = balance + interest_amount,
            updated_at = CURRENT_TIMESTAMP,
            updated_by = '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'  -- System update
        WHERE 
            acc_id = fd_record.acc_id;
        
        -- Update FD next_interest_day to 30 days from now
        UPDATE public.fixed_deposit
        SET 
            next_interest_day = CURRENT_DATE + INTERVAL '30 days',
            updated_at = CURRENT_TIMESTAMP,
            updated_by = '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'  -- System update
        WHERE 
            fd_id = fd_record.fd_id;
        
        -- Log the interest payment (optional)
        RAISE NOTICE 'Interest paid for FD %: Amount %, Next payment date %', 
            fd_record.fd_account_no, 
            interest_amount, 
            CURRENT_DATE + INTERVAL '30 days';
            
    END LOOP;
END;
$$;


--
-- TOC entry 315 (class 1255 OID 31017)
-- Name: process_transfer_transaction(uuid, uuid, numeric, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_transfer_transaction(p_from_acc_id uuid, p_to_acc_id uuid, p_amount numeric, p_description text, p_created_by uuid) RETURNS TABLE(transfer_out_id uuid, transfer_in_id uuid, from_balance numeric, to_balance numeric, success boolean, error_message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    from_current_balance NUMERIC;
    to_current_balance NUMERIC;
    from_updated_balance NUMERIC;
    to_updated_balance NUMERIC;
BEGIN
    -- Validate transfer amount
    IF p_amount <= 0 THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::UUID, 0::NUMERIC, 0::NUMERIC, FALSE, 'Transfer amount must be greater than zero';
        RETURN;
    END IF;

    -- Prevent self-transfer
    IF p_from_acc_id = p_to_acc_id THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::UUID, 0::NUMERIC, 0::NUMERIC, FALSE, 'Cannot transfer to the same account';
        RETURN;
    END IF;

    -- Enforce max transfer limit
    IF p_amount > 100000 THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::UUID, 0::NUMERIC, 0::NUMERIC, FALSE, 'Transfer exceeds maximum limit of Rs.100,000';
        RETURN;
    END IF;

    -- Lock accounts (deadlock prevention)
    IF p_from_acc_id < p_to_acc_id THEN
        SELECT balance INTO from_current_balance FROM account WHERE acc_id = p_from_acc_id FOR UPDATE;
        SELECT balance INTO to_current_balance FROM account WHERE acc_id = p_to_acc_id FOR UPDATE;
    ELSE
        SELECT balance INTO to_current_balance FROM account WHERE acc_id = p_to_acc_id FOR UPDATE;
        SELECT balance INTO from_current_balance FROM account WHERE acc_id = p_from_acc_id FOR UPDATE;
    END IF;

    -- Check account existence
    IF from_current_balance IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, 0::NUMERIC, 0::NUMERIC, FALSE, 'Source account not found';
        RETURN;
    END IF;

    IF to_current_balance IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, from_current_balance, 0::NUMERIC, FALSE, 'Destination account not found';
        RETURN;
    END IF;

    -- Check sufficient balance
    IF from_current_balance < p_amount THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, from_current_balance, to_current_balance, FALSE,
            FORMAT('Insufficient funds. Available: Rs.%s', from_current_balance);
        RETURN;
    END IF;

    -- Maintain minimum balance (Rs.500)
    IF (from_current_balance - p_amount) < 500 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, from_current_balance, to_current_balance, FALSE,
            FORMAT('Transfer would violate Rs.500 minimum balance requirement. Remaining: Rs.%s', from_current_balance - p_amount);
        RETURN;
    END IF;

    -- Calculate new balances
    from_updated_balance := from_current_balance - p_amount;
    to_updated_balance := to_current_balance + p_amount;

    -- Transfer-Out (Debit) transaction
    INSERT INTO transactions (amount, acc_id, type, description, created_by)
    VALUES (
        p_amount,
        p_from_acc_id,
        'BankTransfer-Out',
        COALESCE(p_description, FORMAT('Transfer to account %s', p_to_acc_id)),
        p_created_by
    )
    RETURNING transaction_id INTO transfer_out_id;

    -- Transfer-In (Credit) transaction
    INSERT INTO transactions (amount, acc_id, type, description, created_by)
    VALUES (
        p_amount,
        p_to_acc_id,
        'BankTransfer-In',
        COALESCE(p_description, FORMAT('Transfer from account %s', p_from_acc_id)),
        p_created_by
    )
    RETURNING transaction_id INTO transfer_in_id;

    -- Update account balances
    UPDATE account SET balance = from_updated_balance, updated_at = NOW() WHERE acc_id = p_from_acc_id;
    UPDATE account SET balance = to_updated_balance, updated_at = NOW() WHERE acc_id = p_to_acc_id;

    -- Return success
    RETURN QUERY SELECT 
        transfer_out_id, transfer_in_id, from_updated_balance, to_updated_balance, TRUE, 'Transfer successful';

EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::UUID,
            COALESCE(from_current_balance, 0::NUMERIC),
            COALESCE(to_current_balance, 0::NUMERIC),
            FALSE, FORMAT('Transfer failed: %s', SQLERRM);
END;
$$;


--
-- TOC entry 267 (class 1255 OID 31018)
-- Name: process_withdrawal_transaction(uuid, numeric, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_withdrawal_transaction(p_acc_id uuid, p_amount numeric, p_description text, p_created_by uuid) RETURNS TABLE(transaction_id uuid, reference_no bigint, new_balance numeric, success boolean, error_message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current_balance NUMERIC;
    v_new_balance NUMERIC;
    v_transaction_id UUID;
    v_reference_no BIGINT;
    v_account_status TEXT;
BEGIN
    -- Input validation
    IF p_acc_id IS NULL THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 
            false, 'Account ID cannot be null'::TEXT;
        RETURN;
    END IF;
    
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 
            false, 'Amount must be greater than zero'::TEXT;
        RETURN;
    END IF;
    
    -- Get account details
    SELECT balance, status 
    INTO v_current_balance, v_account_status
    FROM account 
    WHERE acc_id = p_acc_id;

    -- Check if account exists
    IF NOT FOUND THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 
            false, 'Account not found'::TEXT;
        RETURN;
    END IF;
    
    -- Check account status
    IF v_account_status != 'active' THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::BIGINT, v_current_balance, 
            false, 'Account is not active'::TEXT;
        RETURN;
    END IF;
    
    -- Check sufficient balance
    IF v_current_balance < p_amount THEN
        RETURN QUERY SELECT 
            NULL::UUID, NULL::BIGINT, v_current_balance, 
            false, 'Insufficient balance'::TEXT;
        RETURN;
    END IF;
    
    -- Calculate new balance
    v_new_balance = v_current_balance - p_amount;
    
    -- Update account balance
    UPDATE account
    SET balance = v_new_balance
    WHERE acc_id = p_acc_id;
    
    -- Insert transaction record
    INSERT INTO transactions (
        acc_id,
        amount,
        type,
        description,
        created_at,
        created_by
    )
    VALUES (
        p_acc_id,
        p_amount,
        'Withdrawal'::transaction_type,
        COALESCE(p_description, 'Withdrawal'),
        CURRENT_TIMESTAMP,
        p_created_by
    )
    RETURNING transactions.transaction_id, transactions.reference_no
    INTO v_transaction_id, v_reference_no;
    
    -- Return success result
    RETURN QUERY SELECT 
        v_transaction_id, 
        v_reference_no, 
        v_new_balance, 
        true, 
        'Transaction completed successfully'::TEXT;
        
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT 
            NULL::UUID, 
            NULL::BIGINT, 
            NULL::NUMERIC, 
            false, 
            ('Transaction failed: ' || SQLERRM)::TEXT;
END;
$$;


--
-- TOC entry 305 (class 1255 OID 31019)
-- Name: update_branch(uuid, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_branch(p_branch_id uuid, p_name text, p_address text, p_updated_by uuid) RETURNS TABLE(branch_id uuid, name text, address text, created_at timestamp without time zone, updated_at timestamp without time zone, created_by uuid, updated_by uuid)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_branch_id UUID;
    v_name TEXT;
    v_address TEXT;
    v_created_at TIMESTAMP;
    v_updated_at TIMESTAMP;
    v_created_by UUID;
    v_updated_by UUID;

BEGIN
    -- Check if branch exists
    IF NOT EXISTS (SELECT 1 FROM branch WHERE branch.branch_id = p_branch_id) THEN
        RAISE EXCEPTION 'Branch not found';
    END IF;

    -- Update branch with only non-null values
    UPDATE branch 
    SET 
        name = COALESCE(p_name, branch.name),
        address = COALESCE(p_address, branch.address),
        updated_at = NOW(),
        updated_by = p_updated_by
    WHERE branch.branch_id = p_branch_id
    RETURNING branch.branch_id, branch.name, branch.address, branch.created_at, branch.updated_at, branch.created_by, branch.updated_by 
    INTO v_branch_id, v_name, v_address, v_created_at, v_updated_at, v_created_by, v_updated_by;

    -- Return the updated branch
    RETURN QUERY
    SELECT v_branch_id, v_name, v_address, v_created_at, v_updated_at, v_created_by, v_updated_by;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Error: %', SQLERRM;
        RAISE;
END;
$$;


--
-- TOC entry 274 (class 1255 OID 31020)
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fix: Use = instead of :=
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 238 (class 1259 OID 31021)
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    acc_id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_no bigint DEFAULT ((floor((random() * ('9000000000'::bigint)::double precision)) + (1000000000)::double precision))::bigint NOT NULL,
    branch_id uuid,
    savings_plan_id uuid,
    balance numeric(24,12),
    opened_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    status public.account_status DEFAULT 'active'::public.account_status
);


--
-- TOC entry 239 (class 1259 OID 31030)
-- Name: accounts_owner; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts_owner (
    acc_id uuid NOT NULL,
    customer_id uuid NOT NULL
);


--
-- TOC entry 240 (class 1259 OID 31033)
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    audit_id uuid DEFAULT gen_random_uuid() NOT NULL,
    table_name character varying(50) NOT NULL,
    record_id uuid NOT NULL,
    action public.audit_action NOT NULL,
    old_values jsonb,
    changed_fields text[],
    user_id uuid,
    "timestamp" timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- TOC entry 241 (class 1259 OID 31040)
-- Name: branch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch (
    branch_id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(25),
    address character varying(300),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid
);


--
-- TOC entry 242 (class 1259 OID 31046)
-- Name: customer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer (
    customer_id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name character varying(150) NOT NULL,
    address character varying(255),
    phone_number character varying(15),
    nic character varying(14),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    dob date NOT NULL
);


--
-- TOC entry 243 (class 1259 OID 31052)
-- Name: customer_login; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_login (
    login_id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    username character varying(50) NOT NULL,
    password text NOT NULL,
    password_last_update timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid
);


--
-- TOC entry 244 (class 1259 OID 31061)
-- Name: fd_plan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fd_plan (
    fd_plan_id uuid DEFAULT gen_random_uuid() NOT NULL,
    duration integer,
    interest_rate numeric(5,2),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    status public.status_enum DEFAULT 'active'::public.status_enum NOT NULL,
    min_amount bigint DEFAULT 50000 NOT NULL
);


--
-- TOC entry 245 (class 1259 OID 31068)
-- Name: fixed_deposit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit (
    fd_id uuid DEFAULT gen_random_uuid() NOT NULL,
    balance numeric(24,12),
    acc_id uuid,
    opened_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    maturity_date timestamp without time zone,
    fd_plan_id uuid,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    fd_account_no bigint DEFAULT (floor(((random() * (90000000)::double precision) + (10000000)::double precision)))::bigint,
    status public.status_enum DEFAULT 'active'::public.status_enum NOT NULL,
    next_interest_day date NOT NULL
);


--
-- TOC entry 259 (class 1259 OID 31506)
-- Name: fixed_deposit_details; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.fixed_deposit_details AS
 SELECT fd.fd_id,
    fd.fd_account_no,
    fd.balance,
    fd.acc_id,
    fd.opened_date,
    fd.maturity_date,
    fd.fd_plan_id,
    fd.created_at AS fd_created_at,
    fd.updated_at AS fd_updated_at,
    fd.status,
    fd.next_interest_day,
    a.account_no,
    b.name AS branch_name,
    fp.duration AS plan_duration,
    fp.interest_rate AS plan_interest_rate
   FROM (((public.fixed_deposit fd
     LEFT JOIN public.account a ON ((fd.acc_id = a.acc_id)))
     LEFT JOIN public.branch b ON ((a.branch_id = b.branch_id)))
     LEFT JOIN public.fd_plan fp ON ((fd.fd_plan_id = fp.fd_plan_id)));


--
-- TOC entry 246 (class 1259 OID 31082)
-- Name: login; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login (
    log_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    login_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    ip_address character varying(45),
    device_info text
);


--
-- TOC entry 247 (class 1259 OID 31089)
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role (
    role_id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_name character varying(50) NOT NULL
);


--
-- TOC entry 248 (class 1259 OID 31093)
-- Name: savings_plan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_plan (
    savings_plan_id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_name character varying(100),
    interest_rate numeric(5,2),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    minimum_balance bigint DEFAULT 0 NOT NULL
);


--
-- TOC entry 249 (class 1259 OID 31099)
-- Name: transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transactions (
    transaction_id uuid DEFAULT gen_random_uuid() NOT NULL,
    amount numeric(12,2) NOT NULL,
    acc_id uuid,
    type public.transaction_type NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    reference_no bigint DEFAULT (floor((random() * ('1000000000000000'::numeric)::double precision)))::bigint
);


--
-- TOC entry 250 (class 1259 OID 31107)
-- Name: user_login; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_login (
    login_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    username character varying(50) NOT NULL,
    password text NOT NULL,
    password_last_update timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    status public.status_enum DEFAULT 'active'::public.status_enum NOT NULL
);


--
-- TOC entry 251 (class 1259 OID 31117)
-- Name: user_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_refresh_tokens (
    token_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    is_revoked boolean DEFAULT false,
    device_info text,
    ip_address inet,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    revoked_at timestamp without time zone,
    revoked_by uuid
);


--
-- TOC entry 252 (class 1259 OID 31126)
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nic character varying(12),
    first_name character varying(100) NOT NULL,
    last_name character varying(100) NOT NULL,
    address character varying(100),
    phone_number character varying(15),
    dob date,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    email character varying(100)
);


--
-- TOC entry 253 (class 1259 OID 31132)
-- Name: users_branch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_branch (
    user_id uuid NOT NULL,
    branch_id uuid NOT NULL
);


--
-- TOC entry 254 (class 1259 OID 31135)
-- Name: users_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_role (
    user_id uuid NOT NULL,
    role_id uuid NOT NULL
);


--
-- TOC entry 3456 (class 0 OID 31410)
-- Dependencies: 256
-- Data for Name: job; Type: TABLE DATA; Schema: cron; Owner: -
--

INSERT INTO cron.job VALUES (1, '5 0 1 * *', '
    SELECT calculate_monthly_interest();
    ', 'localhost', 5432, 'postgres', 'postgres', true, 'monthly_interest_job');
INSERT INTO cron.job VALUES (6, '0 0 * * *', 'SELECT daily_fd_interest_check()', 'localhost', 5432, 'postgres', 'postgres', true, 'fd-interest-daily');


--
-- TOC entry 3458 (class 0 OID 31429)
-- Dependencies: 258
-- Data for Name: job_run_details; Type: TABLE DATA; Schema: cron; Owner: -
--



--
-- TOC entry 3791 (class 0 OID 31021)
-- Dependencies: 238
-- Data for Name: account; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.account VALUES ('0415f29e-fb5b-4756-baa6-bce59cab2be5', 9740325119, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 514564.991228631193, '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('1b337986-ae2d-4e9e-9f87-5bd92e29253f', 1234567890, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 1084.708364899762, '2025-09-18 13:56:05.448161', '2025-09-18 13:56:05.448161', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('31d95fe1-7d2f-4d9e-81c1-b608131b7335', 1623490919, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 232.284854231852, '2025-10-15 10:39:31.756196', '2025-10-15 10:39:31.756196', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('3337ad45-7e90-4c8f-9057-e38f3c43f196', 1111111111, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 49306.821430297404, '2025-09-18 14:43:34.844831', '2025-09-18 14:43:34.844831', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('58f8da96-a4c1-4071-8a8c-a195b70bb040', 2815823974, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 448429.136902675947, '2025-09-24 17:50:34.479023', '2025-09-24 17:50:34.479023', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('820e7b5a-8b66-4242-b7e0-a49e9880b17e', 5641582760, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 7271.154249538204, '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('8f453f53-bf51-437c-b8a9-702b08caf92d', 2252112086, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 14580.551575090717, '2025-10-15 11:01:38.812598', '2025-10-15 11:01:38.812598', '2025-10-16 12:01:19.431619', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('3b4fe46d-d998-4231-bf48-9552830244fe', 5332947752, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '75cb0dfb-be48-4b4c-ab13-9e01772f0332', 21640.689374346185, '2025-08-17 08:35:17.556107', '2025-08-17 08:35:17.556107', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('6793b998-92c2-45bb-a4d4-1b84fefbc652', 8799688614, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 34174.928201724732, '2025-08-31 08:31:39.843262', '2025-08-31 08:31:39.843262', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('1dfe7946-7b05-4de1-8254-1528660baf18', 2144095367, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 35220.525375545576, '2025-08-07 13:31:48.382933', '2025-08-07 13:31:48.382933', '2025-10-16 12:01:19.431619', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 7567760433, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 27398.157369615490, '2025-08-17 08:38:49.506264', '2025-08-17 08:38:49.506264', '2025-10-16 12:01:19.431619', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 6695094450, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 573000.540688239207, '2025-08-17 08:40:50.934841', '2025-08-17 08:40:50.934841', '2025-10-16 12:01:19.431619', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 5398529687, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 93335.423305580967, '2025-08-04 10:38:17.380613', '2025-08-04 10:38:17.380613', '2025-10-03 12:01:10.850765', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('17c9a664-3b42-456e-95e4-4bd73353f0e0', 3626616376, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 27176.136389972173, '2025-08-27 08:30:03.951331', '2025-08-27 08:30:03.951331', '2025-09-26 14:45:06.944417', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('4dcf9c4f-2bec-49f9-a336-5e45cce1601b', 8020135334, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '75cb0dfb-be48-4b4c-ab13-9e01772f0332', 500.000000000000, '2025-08-07 13:35:40.596114', '2025-08-07 13:35:40.596114', '2025-10-20 12:00:04.300559', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'closed');
INSERT INTO public.account VALUES ('1853d4ea-a229-4757-9a4c-f6f858351196', 3217307079, '57438d7f-184f-42fe-b0d6-91a2ef609beb', 'fd8afec3-3da2-48ab-a63d-abbff3a3e773', 38898.856012800064, '2025-09-10 15:04:03.795948', '2025-09-10 15:04:03.795948', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('2955457b-8207-4228-a3da-c9d5940c2095', 4027545623, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '75cb0dfb-be48-4b4c-ab13-9e01772f0332', 23025.577673194262, '2025-09-05 10:33:30.449363', '2025-09-05 10:33:30.449363', '2025-10-16 11:58:04.657419', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'active');
INSERT INTO public.account VALUES ('2effb977-c5cb-43cb-9c5e-7db80de361e4', 3166815096, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 2809521.696011775550, '2025-09-15 11:03:20.019027', '2025-09-15 11:03:20.019027', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('30159eb0-328d-4cf2-84a3-d7f51040ed22', 6401639306, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 476586.245907260330, '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '2025-10-16 11:58:04.657419', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('4ae3fefd-a3d4-4133-b516-bddebdf3d49f', 9626175859, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 675633.180671847354, '2025-09-10 15:07:10.783714', '2025-09-10 15:07:10.783714', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('697a0943-3418-427b-9786-45b5c5066b71', 3474646697, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 29015.702293047427, '2025-09-01 08:36:17.000525', '2025-09-01 08:36:17.000525', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('6c66d02c-2753-4163-ae2a-9f2ffcd0574b', 3579884893, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 761804.670535527485, '2025-09-30 11:00:05.550255', '2025-09-30 11:00:05.550255', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('20a94040-fbf0-4e7a-ae5f-c6e766a134ca', 1546227556, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 31105.080878213548, '2025-10-20 12:00:38.78147', '2025-10-20 12:00:38.78147', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('7fe7a775-2411-423a-84fa-e3ed126ec6c3', 5561587952, '57438d7f-184f-42fe-b0d6-91a2ef609beb', 'a620a5c0-9456-4bc6-a37c-1c02d8f0da9c', 27413.388761492969, '2025-09-10 15:02:09.020212', '2025-09-10 15:02:09.020212', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('84f57e11-cd1b-40cf-b70b-e67a538ded88', 3660390474, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 84717.799467736533, '2025-09-05 10:34:14.39367', '2025-09-05 10:34:14.39367', '2025-10-16 11:58:04.657419', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'active');
INSERT INTO public.account VALUES ('89e221cd-2b08-47c5-a88f-3ceffa79fb9a', 8786850818, '3736a1a3-5fdc-455e-96be-1269df99e9a5', 'a620a5c0-9456-4bc6-a37c-1c02d8f0da9c', 106343.455667062711, '2025-09-05 10:36:18.181905', '2025-09-05 10:36:18.181905', '2025-10-16 11:58:04.657419', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'active');
INSERT INTO public.account VALUES ('99280df3-2bad-4c61-b069-bf6144235552', 9278010342, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 27669.015242700327, '2025-08-29 08:33:54.158792', '2025-08-29 08:33:54.158792', '2025-09-30 12:01:03.698862', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('a6b1bdd7-e70e-4dd8-8621-397d69fb3300', 4981569672, '57438d7f-184f-42fe-b0d6-91a2ef609beb', 'fd8afec3-3da2-48ab-a63d-abbff3a3e773', 578270.229418897694, '2025-10-01 12:00:47.112878', '2025-10-01 12:00:47.112878', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('f4a8e8d5-92af-421d-a437-dce94fd12638', 4687329928, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 90452.554130137253, '2025-08-04 10:45:04.650629', '2025-08-04 10:45:04.650629', '2025-09-26 14:45:06.944417', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('a949c77a-bb3b-484f-9b3e-8d68a36deb87', 9888415978, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 14283.099435300091, '2025-08-27 08:37:36.62256', '2025-08-27 08:37:36.62256', '2025-09-26 14:45:06.944417', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('b79aefad-de0e-4387-84cb-7a1234ce4ce7', 9924372791, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 49822.249480078367, '2025-08-27 08:33:21.854083', '2025-08-27 08:33:21.854083', '2025-09-26 14:45:06.944417', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('b0134b68-04e3-4e00-a0ac-dabe67c9612f', 2770729143, '3dd6870c-e6f2-414d-9973-309ba00ce115', '75cb0dfb-be48-4b4c-ab13-9e01772f0332', 133750.429311734296, '2025-10-14 15:32:34.730917', '2025-10-14 15:32:34.730917', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('b646dd25-7775-417f-a216-30a84aa9c451', 5981675752, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 2068363.186806755470, '2025-08-04 10:41:28.424569', '2025-08-04 10:41:28.424569', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('c1e74ae4-f466-4769-9649-f8064a7e6a89', 6052845866, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 11229.034849217283, '2025-09-24 14:56:44.494199', '2025-09-24 14:56:44.494199', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('c6b21347-9458-4f2b-8b03-4c479c60315e', 1399861390, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 3237180.259815663778, '2025-08-04 10:43:46.657443', '2025-08-04 10:43:46.657443', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('d00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 6602045229, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 333456.650710822393, '2025-08-04 10:37:07.826495', '2025-08-04 10:37:07.826495', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('ded1f289-7f01-4135-b638-dd735d691229', 8991316384, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 48501.318265778140, '2025-09-10 12:31:11.092921', '2025-09-10 12:31:11.092921', '2025-10-16 11:58:04.657419', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'active');
INSERT INTO public.account VALUES ('dffecccc-565a-4b66-804c-1befa178b8f7', 9811462445, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 104716.463174022737, '2025-08-04 11:00:17.49844', '2025-08-04 11:00:17.49844', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 8120354779, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 10617.116599529478, '2025-09-24 19:39:23.999379', '2025-09-24 19:39:23.999379', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('e260aeef-4836-4a35-bb19-3d109adba141', 9547207573, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '75cb0dfb-be48-4b4c-ab13-9e01772f0332', 10820.344687173093, '2025-08-17 08:33:58.744699', '2025-08-17 08:33:58.744699', '2025-10-16 11:58:04.657419', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'active');
INSERT INTO public.account VALUES ('9f195429-65fc-48c0-8a22-3216088f897e', 6341929450, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 49913.913053162356, '2025-08-07 13:31:34.591448', '2025-08-07 13:31:34.591448', '2025-10-16 12:01:19.431619', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('e085d6e0-4e81-4dd5-b124-fae6a038a453', 9900817372, '3736a1a3-5fdc-455e-96be-1269df99e9a5', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 527706.172972722560, '2025-08-04 10:48:22.7342', '2025-08-04 10:48:22.7342', '2025-10-03 12:01:10.850765', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('d38f3e7a-9414-40e4-b62f-47019c16be6b', 3638811642, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 53937.835697583266, '2025-08-29 08:30:12.254856', '2025-08-29 08:30:12.254856', '2025-09-28 12:01:06.107982', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('fb762c41-c883-4bba-9bcf-f59dfc07f042', 1529729150, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 1703.414759230828, '2025-10-15 00:55:47.52668', '2025-10-15 00:55:47.52668', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 123456789, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 2155.484826638514, '2025-09-18 14:07:15.807623', '2025-09-18 14:07:15.807623', '2025-10-16 11:58:04.657419', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'active');
INSERT INTO public.account VALUES ('fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 5233589009, '3dd6870c-e6f2-414d-9973-309ba00ce115', 'fd8afec3-3da2-48ab-a63d-abbff3a3e773', 52624.387898848771, '2025-10-15 09:22:06.611902', '2025-10-15 09:22:06.611902', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('fde6ebe4-72be-4574-a470-999a365b1529', 8283584064, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 1276.968496355866, '2025-10-15 01:47:09.659802', '2025-10-15 01:47:09.659802', '2025-10-16 11:58:04.657419', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');


--
-- TOC entry 3792 (class 0 OID 31030)
-- Dependencies: 239
-- Data for Name: accounts_owner; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.accounts_owner VALUES ('1b337986-ae2d-4e9e-9f87-5bd92e29253f', '12d17661-847d-4385-9fd2-ea582da813b2');
INSERT INTO public.accounts_owner VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', '96a6ea17-b2d3-40d0-9c5b-903da6280f50');
INSERT INTO public.accounts_owner VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('3337ad45-7e90-4c8f-9057-e38f3c43f196', '97da5431-f39a-43e5-b0cd-9d185327b6e6');
INSERT INTO public.accounts_owner VALUES ('c1e74ae4-f466-4769-9649-f8064a7e6a89', '12d17661-847d-4385-9fd2-ea582da813b2');
INSERT INTO public.accounts_owner VALUES ('58f8da96-a4c1-4071-8a8c-a195b70bb040', '8f99e4a7-47ed-44ea-947f-89dae567a52c');
INSERT INTO public.accounts_owner VALUES ('e03ca11a-ea04-4acd-9a81-66dd51d95cfa', '8f99e4a7-47ed-44ea-947f-89dae567a52c');
INSERT INTO public.accounts_owner VALUES ('820e7b5a-8b66-4242-b7e0-a49e9880b17e', '4ab20e7b-e5c7-4331-b75d-2135c62c4ac7');
INSERT INTO public.accounts_owner VALUES ('b0134b68-04e3-4e00-a0ac-dabe67c9612f', '96a6ea17-b2d3-40d0-9c5b-903da6280f50');
INSERT INTO public.accounts_owner VALUES ('fb762c41-c883-4bba-9bcf-f59dfc07f042', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('fde6ebe4-72be-4574-a470-999a365b1529', '96a6ea17-b2d3-40d0-9c5b-903da6280f50');
INSERT INTO public.accounts_owner VALUES ('fde6ebe4-72be-4574-a470-999a365b1529', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('31d95fe1-7d2f-4d9e-81c1-b608131b7335', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('31d95fe1-7d2f-4d9e-81c1-b608131b7335', '97da5431-f39a-43e5-b0cd-9d185327b6e6');
INSERT INTO public.accounts_owner VALUES ('0415f29e-fb5b-4756-baa6-bce59cab2be5', '277ccc80-9a20-438e-93a9-459f041b145d');
INSERT INTO public.accounts_owner VALUES ('8f453f53-bf51-437c-b8a9-702b08caf92d', '97da5431-f39a-43e5-b0cd-9d185327b6e6');
INSERT INTO public.accounts_owner VALUES ('8f453f53-bf51-437c-b8a9-702b08caf92d', '96a6ea17-b2d3-40d0-9c5b-903da6280f50');
INSERT INTO public.accounts_owner VALUES ('d00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'ba15de27-893c-4915-bc20-6e56ab35b60b');
INSERT INTO public.accounts_owner VALUES ('2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'e1dd007e-8c4a-4607-b462-7239452c4d10');
INSERT INTO public.accounts_owner VALUES ('b646dd25-7775-417f-a216-30a84aa9c451', '9609c225-a1dd-4eb6-b8c1-2908bd73cd3f');
INSERT INTO public.accounts_owner VALUES ('c6b21347-9458-4f2b-8b03-4c479c60315e', 'f848f8ae-9948-4406-a017-21c2ba879c8c');
INSERT INTO public.accounts_owner VALUES ('c6b21347-9458-4f2b-8b03-4c479c60315e', '56850cc8-ac6d-46bf-89b7-34b3b38a20f2');
INSERT INTO public.accounts_owner VALUES ('f4a8e8d5-92af-421d-a437-dce94fd12638', '5175ad1e-2b6e-4669-b46a-d0695abe67f5');
INSERT INTO public.accounts_owner VALUES ('e085d6e0-4e81-4dd5-b124-fae6a038a453', '5175ad1e-2b6e-4669-b46a-d0695abe67f5');
INSERT INTO public.accounts_owner VALUES ('e085d6e0-4e81-4dd5-b124-fae6a038a453', 'd2da339f-07f6-4914-aa0e-23a9d3a58c21');
INSERT INTO public.accounts_owner VALUES ('dffecccc-565a-4b66-804c-1befa178b8f7', '56850cc8-ac6d-46bf-89b7-34b3b38a20f2');
INSERT INTO public.accounts_owner VALUES ('dffecccc-565a-4b66-804c-1befa178b8f7', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('9f195429-65fc-48c0-8a22-3216088f897e', '183dc79e-1b46-4531-948a-9072182795c8');
INSERT INTO public.accounts_owner VALUES ('1dfe7946-7b05-4de1-8254-1528660baf18', '8a99b924-6b64-487d-974e-c44b5a0ca190');
INSERT INTO public.accounts_owner VALUES ('4dcf9c4f-2bec-49f9-a336-5e45cce1601b', 'c5690609-4d4f-4f3e-a852-53acd69ac3d3');
INSERT INTO public.accounts_owner VALUES ('e260aeef-4836-4a35-bb19-3d109adba141', '5371829a-831a-4c94-8f62-f50c6a3b9191');
INSERT INTO public.accounts_owner VALUES ('3b4fe46d-d998-4231-bf48-9552830244fe', '8515c62b-c3f0-4d94-955b-b63e6a8390d8');
INSERT INTO public.accounts_owner VALUES ('3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 'b76a9d5c-3891-4491-9163-b03bc53f0141');
INSERT INTO public.accounts_owner VALUES ('4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'f610dff2-6f8b-44e3-9af8-be31cacb3560');
INSERT INTO public.accounts_owner VALUES ('17c9a664-3b42-456e-95e4-4bd73353f0e0', 'ba15de27-893c-4915-bc20-6e56ab35b60b');
INSERT INTO public.accounts_owner VALUES ('b79aefad-de0e-4387-84cb-7a1234ce4ce7', 'e1dd007e-8c4a-4607-b462-7239452c4d10');
INSERT INTO public.accounts_owner VALUES ('a949c77a-bb3b-484f-9b3e-8d68a36deb87', '9609c225-a1dd-4eb6-b8c1-2908bd73cd3f');
INSERT INTO public.accounts_owner VALUES ('d38f3e7a-9414-40e4-b62f-47019c16be6b', '183dc79e-1b46-4531-948a-9072182795c8');
INSERT INTO public.accounts_owner VALUES ('99280df3-2bad-4c61-b069-bf6144235552', '12d17661-847d-4385-9fd2-ea582da813b2');
INSERT INTO public.accounts_owner VALUES ('6793b998-92c2-45bb-a4d4-1b84fefbc652', '12d17661-847d-4385-9fd2-ea582da813b2');
INSERT INTO public.accounts_owner VALUES ('30159eb0-328d-4cf2-84a3-d7f51040ed22', '8547efd6-d5d5-4368-b560-fe08f9834a25');
INSERT INTO public.accounts_owner VALUES ('30159eb0-328d-4cf2-84a3-d7f51040ed22', '5994c156-fcc4-4df3-bf6e-10905603941e');
INSERT INTO public.accounts_owner VALUES ('697a0943-3418-427b-9786-45b5c5066b71', '183dc79e-1b46-4531-948a-9072182795c8');
INSERT INTO public.accounts_owner VALUES ('2955457b-8207-4228-a3da-c9d5940c2095', 'c77b68a3-2bdc-4c73-ae4c-1f0331757154');
INSERT INTO public.accounts_owner VALUES ('84f57e11-cd1b-40cf-b70b-e67a538ded88', '8a99b924-6b64-487d-974e-c44b5a0ca190');
INSERT INTO public.accounts_owner VALUES ('89e221cd-2b08-47c5-a88f-3ceffa79fb9a', 'c5690609-4d4f-4f3e-a852-53acd69ac3d3');
INSERT INTO public.accounts_owner VALUES ('ded1f289-7f01-4135-b638-dd735d691229', 'f610dff2-6f8b-44e3-9af8-be31cacb3560');
INSERT INTO public.accounts_owner VALUES ('7fe7a775-2411-423a-84fa-e3ed126ec6c3', '07709cbf-2053-430c-a478-ae7cef5327a2');
INSERT INTO public.accounts_owner VALUES ('1853d4ea-a229-4757-9a4c-f6f858351196', '08c15d5a-82f4-4b69-93de-37a76f2f7533');
INSERT INTO public.accounts_owner VALUES ('4ae3fefd-a3d4-4133-b516-bddebdf3d49f', '183dc79e-1b46-4531-948a-9072182795c8');
INSERT INTO public.accounts_owner VALUES ('2effb977-c5cb-43cb-9c5e-7db80de361e4', 'c1f52f03-9b0e-4b5d-8ec7-7df36d52f2e8');
INSERT INTO public.accounts_owner VALUES ('2effb977-c5cb-43cb-9c5e-7db80de361e4', '6e7cb74e-b103-49e2-b3a7-ef9fabe4754b');
INSERT INTO public.accounts_owner VALUES ('6c66d02c-2753-4163-ae2a-9f2ffcd0574b', '8c72faa2-beb5-458d-80ac-dfff02cb4ce9');
INSERT INTO public.accounts_owner VALUES ('a6b1bdd7-e70e-4dd8-8621-397d69fb3300', 'a32bd7d9-c3ca-4d17-8679-1aabd6634d37');
INSERT INTO public.accounts_owner VALUES ('20a94040-fbf0-4e7a-ae5f-c6e766a134ca', '32f76078-4238-4898-95bd-e76a16ca8e3f');


--
-- TOC entry 3793 (class 0 OID 31033)
-- Dependencies: 240
-- Data for Name: audit_log; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.audit_log VALUES ('e725be3d-ade7-4881-ab46-2dceae2bdad8', 'users', 'de9dc531-11bf-4481-882a-dc3291580f60', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-09-18 07:09:21.535303');
INSERT INTO public.audit_log VALUES ('cd24de61-14f1-4914-a477-51dcfd564c21', 'users', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 07:19:23.418837');
INSERT INTO public.audit_log VALUES ('b85bcf9b-0083-4f87-b74d-f436f210439a', 'users', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 14:04:14.712609');
INSERT INTO public.audit_log VALUES ('2469da8a-bac2-4709-9294-cbc8a8f6426c', 'users', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 14:18:45.238594');
INSERT INTO public.audit_log VALUES ('9ea0b31d-a591-4fb2-8ed0-180ccaf53064', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$bSFckspDwP6xitca5lzn1.NiWT8qK3Q5nZ5HpD7YsPMP7ky5.7re.", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-09-18T07:19:23.418837", "updated_by": "de9dc531-11bf-4481-882a-dc3291580f60", "password_last_update": "2025-09-18T07:19:23.418837"}', '{password,updated_at}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-16 01:08:37.875766');
INSERT INTO public.audit_log VALUES ('025f7ce5-64b6-4bde-88c3-8a2d0732a3ba', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$ERMywOCfFYKpIgBeEIiRhevYIbR7Q1PYaxMriTg5GXTbKGTQ1Ms2O", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-16T01:08:37.875766", "updated_by": "de9dc531-11bf-4481-882a-dc3291580f60", "password_last_update": "2025-09-18T07:19:23.418837"}', '{password,updated_at}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-16 01:24:12.53565');
INSERT INTO public.audit_log VALUES ('6ecd9ac6-7fa4-4231-9030-d5743c4c965b', 'user_login', 'e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd', 'UPDATE', '{"status": "active", "user_id": "de9dc531-11bf-4481-882a-dc3291580f60", "login_id": "e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd", "password": "$2b$12$3FeUn7kyl4KDB/Yc2w2uUe4wC2OOpRi5bLskalPsihcZ7K2/wRe0K", "username": "user1", "created_at": "2025-09-18T07:09:21.535303", "created_by": "839c9a79-9f0a-4ba7-9d4c-91358f9b93b1", "updated_at": "2025-09-18T07:09:21.535303", "updated_by": "839c9a79-9f0a-4ba7-9d4c-91358f9b93b1", "password_last_update": "2025-09-18T07:09:21.535303"}', '{password,updated_at}', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-10-17 21:26:22.683731');
INSERT INTO public.audit_log VALUES ('b2eb4f2f-d676-44cb-9258-26a1c4072975', 'user_login', 'e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd', 'UPDATE', '{"status": "active", "user_id": "de9dc531-11bf-4481-882a-dc3291580f60", "login_id": "e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd", "password": "$2b$12$8812BrkcVPxFTSqHrYkaCepZ1ci8ZXJg94u/XmCyKl6vIEB.wZ2le", "username": "user1", "created_at": "2025-09-18T07:09:21.535303", "created_by": "839c9a79-9f0a-4ba7-9d4c-91358f9b93b1", "updated_at": "2025-10-17T21:26:22.683731", "updated_by": "839c9a79-9f0a-4ba7-9d4c-91358f9b93b1", "password_last_update": "2025-09-18T07:09:21.535303"}', '{password,updated_at}', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-10-17 21:28:05.066993');
INSERT INTO public.audit_log VALUES ('3d334ecd-d3cc-45f2-9040-6b2206d943fe', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$CfMjiY0Y.G1CbzVNXqHZwuj9YtiM38zJ3UIGvwc3K4d55cQ4KoKHm", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-16T01:24:12.53565", "updated_by": "de9dc531-11bf-4481-882a-dc3291580f60", "password_last_update": "2025-09-18T07:19:23.418837"}', '{status,updated_at,updated_by}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 01:25:14.926847');
INSERT INTO public.audit_log VALUES ('82da1c7c-6cb0-41aa-86f7-2b05f034af18', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "inactive", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$CfMjiY0Y.G1CbzVNXqHZwuj9YtiM38zJ3UIGvwc3K4d55cQ4KoKHm", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-18T01:25:14.926847", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{status,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 01:25:16.751189');
INSERT INTO public.audit_log VALUES ('5c7698e1-e6ef-4c14-8207-5f488efe59fd', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$CfMjiY0Y.G1CbzVNXqHZwuj9YtiM38zJ3UIGvwc3K4d55cQ4KoKHm", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-18T01:25:16.751189", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{password,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 01:25:25.79255');
INSERT INTO public.audit_log VALUES ('08f90ce2-e414-4cb5-a88f-028aceece033', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$XVHww3/0loLkbW33mBNfAORX9B8RwypNy7oEj495xdOub8cMYUh.2", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-18T01:25:25.79255", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{password,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 01:25:34.952433');
INSERT INTO public.audit_log VALUES ('a555f7da-f79a-4dea-87c8-544f36adecf0', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-18T01:25:34.952433", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{status,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:18:04.126019');
INSERT INTO public.audit_log VALUES ('48ab0a8f-12ad-4f72-9950-9db0990255ab', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "inactive", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-20T17:18:04.126019", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{status,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:18:23.919709');
INSERT INTO public.audit_log VALUES ('e29b4789-cc42-43bc-a8ed-106e019d2f3e', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-20T17:18:23.919709", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{status,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:18:24.623746');
INSERT INTO public.audit_log VALUES ('6ecd7dcd-1dc9-4ba9-bb11-21157afb0995', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "inactive", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-20T17:18:24.623746", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{status,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:18:34.077441');
INSERT INTO public.audit_log VALUES ('f32a5305-9e93-40a4-9bb0-a66d95c9c858', 'user_login', 'e67ce6c6-bb0d-46cf-a222-860e548822a0', 'UPDATE', '{"status": "active", "user_id": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09", "login_id": "e67ce6c6-bb0d-46cf-a222-860e548822a0", "password": "$2b$12$w8czX6DDYjBiJvdIjOpxVOatGl32Ca4nX40N9A2fWvsPjPTltraB6", "username": "user3", "created_at": "2025-09-18T14:04:14.712609", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-09-18T14:04:14.712609", "updated_by": "de9dc531-11bf-4481-882a-dc3291580f60", "password_last_update": "2025-09-18T14:04:14.712609"}', '{username,updated_at}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-08-04 10:45:38.225101');
INSERT INTO public.audit_log VALUES ('b146bc01-6608-4601-9c8f-f763a15f8dfa', 'user_login', '86295c07-2139-4499-9410-d729b012cfb7', 'UPDATE', '{"status": "active", "user_id": "75cf1bda-3240-41c5-8235-5a0f06d51fa7", "login_id": "86295c07-2139-4499-9410-d729b012cfb7", "password": "$2b$12$K4ZpGK2cPR0kivNqhtVRzO6vkOSkFKOkx/zNiAKuREJEqVu.BQ.y2", "username": "user4", "created_at": "2025-09-18T14:18:45.238594", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-09-18T14:18:45.238594", "updated_by": "de9dc531-11bf-4481-882a-dc3291580f60", "password_last_update": "2025-09-18T14:18:45.238594"}', '{username,updated_at}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-08-04 10:45:38.230918');
INSERT INTO public.audit_log VALUES ('6311d37c-dce5-4cdc-a5ea-46614d23a34d', 'user_login', 'e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd', 'UPDATE', '{"status": "active", "user_id": "de9dc531-11bf-4481-882a-dc3291580f60", "login_id": "e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd", "password": "$2b$12$14vPB5UI74Cs/6gIah46wecLcncl4.0qcBQ9XqtXLkFvYj9e5qYIC", "username": "user1", "created_at": "2025-09-18T07:09:21.535303", "created_by": "839c9a79-9f0a-4ba7-9d4c-91358f9b93b1", "updated_at": "2025-10-17T21:28:05.066993", "updated_by": "839c9a79-9f0a-4ba7-9d4c-91358f9b93b1", "password_last_update": "2025-09-18T07:09:21.535303"}', '{username,updated_at}', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-08-04 10:45:38.23354');
INSERT INTO public.audit_log VALUES ('69364c1b-e7cd-44d1-8f85-0c323b9ceba2', 'user_login', '8e940780-67c7-42e8-a307-4a92664ab72f', 'UPDATE', '{"status": "active", "user_id": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "login_id": "8e940780-67c7-42e8-a307-4a92664ab72f", "password": "$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K", "username": "user2", "created_at": "2025-09-18T07:19:23.418837", "created_by": "de9dc531-11bf-4481-882a-dc3291580f60", "updated_at": "2025-10-20T17:18:34.077441", "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5", "password_last_update": "2025-09-18T07:19:23.418837"}', '{username,updated_at}', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:45:38.235628');


--
-- TOC entry 3794 (class 0 OID 31040)
-- Dependencies: 241
-- Data for Name: branch; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.branch VALUES ('57438d7f-184f-42fe-b0d6-91a2ef609beb', 'Jaffna', 'Jaffna', '2025-07-18 07:07:02.375', '2025-08-04 10:54:53.176064', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1');
INSERT INTO public.branch VALUES ('50cf15c8-b810-4a5c-8400-79cfe791aba4', 'Moratuwa', 'Katubadda, Moratuwa', '2025-07-04 01:23:35.796', '2025-08-04 10:54:53.181862', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.branch VALUES ('3dd6870c-e6f2-414d-9973-309ba00ce115', 'Colombo', 'colombore', '2025-07-18 07:05:43.839', '2025-08-04 10:54:53.183828', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.branch VALUES ('3639c0dc-bda3-472e-8a06-5f8a4e36c42a', 'Galle', 'Galle', '2025-07-14 13:14:51.355', '2025-08-04 11:08:52.309649', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.branch VALUES ('3736a1a3-5fdc-455e-96be-1269df99e9a5', 'Kurunegala', 'Kurunegala', '2025-07-15 02:10:06.066', '2025-08-04 11:08:52.311843', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.branch VALUES ('12af5190-d280-4842-addf-6c66312b4ffc', 'Kandy', 'Kandy', '2025-07-15 02:19:49.448', '2025-08-04 11:08:52.313812', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');


--
-- TOC entry 3795 (class 0 OID 31046)
-- Dependencies: 242
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.customer VALUES ('12d17661-847d-4385-9fd2-ea582da813b2', 'customer 3', 'colombo', '0745879866', '200147897589', '2025-09-18 14:33:26.650656', '2025-09-18 14:33:26.650656', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-02-06');
INSERT INTO public.customer VALUES ('4ab20e7b-e5c7-4331-b75d-2135c62c4ac7', 'customer 8', 'moratuwa', '0721458654', '200302154789', '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2003-10-10');
INSERT INTO public.customer VALUES ('97da5431-f39a-43e5-b0cd-9d185327b6e6', 'new name', 'new address', '0465879523', '211454546587', '2025-09-18 14:41:28.403699', '2025-10-15 03:27:14.502344', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-02-06');
INSERT INTO public.customer VALUES ('96a6ea17-b2d3-40d0-9c5b-903da6280f50', 'customer 1', 'jafna', '0724548799', '20045454654', '2025-09-18 14:29:18.039149', '2025-10-15 03:36:44.284379', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-02-06');
INSERT INTO public.customer VALUES ('8f99e4a7-47ed-44ea-947f-89dae567a52c', 'customer7', 'string', 'string', '200254545879', '2025-09-24 17:50:34.479023', '2025-10-15 03:37:09.790343', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-11-11');
INSERT INTO public.customer VALUES ('277ccc80-9a20-438e-93a9-459f041b145d', '1212', 'eqdwda', '0778877546', '321656332323', '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-09');
INSERT INTO public.customer VALUES ('f0bf0ef8-0015-4c79-bae4-bab26d897409', 'new name 2', 'new addres', '07553122', '20058795645', '2025-09-18 14:29:55.137535', '2025-10-15 12:37:03.439601', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-02-06');
INSERT INTO public.customer VALUES ('ba15de27-893c-4915-bc20-6e56ab35b60b', 'Meena Kumari', 'Wawuniya ', '0374523174', '200098234567', '2025-08-04 10:37:07.826495', '2025-08-04 10:37:07.826495', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2000-11-23');
INSERT INTO public.customer VALUES ('e1dd007e-8c4a-4607-b462-7239452c4d10', 'Saman Kumara', 'Kilinochchi', '0231122384', '200198234567', '2025-08-04 10:38:17.380613', '2025-08-04 10:38:17.380613', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2001-02-03');
INSERT INTO public.customer VALUES ('9609c225-a1dd-4eb6-b8c1-2908bd73cd3f', 'Sangeeth Banda', 'Nagadeepa', '0934523875', '200298234567', '2025-08-04 10:41:28.424569', '2025-08-04 10:41:28.424569', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2002-04-05');
INSERT INTO public.customer VALUES ('f848f8ae-9948-4406-a017-21c2ba879c8c', 'Nimesha Sandeepani', 'Dhabakola Patuna', '0231144586', '200011253493', '2025-08-04 10:43:46.657443', '2025-08-04 10:43:46.657443', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2000-06-11');
INSERT INTO public.customer VALUES ('56850cc8-ac6d-46bf-89b7-34b3b38a20f2', 'Himaya Bandara', 'Dhabakola Patuna', '0823342765', '200011253494', '2025-08-04 10:43:46.657443', '2025-08-04 10:43:46.657443', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2000-05-12');
INSERT INTO public.customer VALUES ('5175ad1e-2b6e-4669-b46a-d0695abe67f5', 'Malsha Dissanayaka', 'Polgahawela', '0789654123', '200352400889', '2025-08-04 10:45:04.650629', '2025-08-04 10:45:04.650629', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2003-01-20');
INSERT INTO public.customer VALUES ('d2da339f-07f6-4914-aa0e-23a9d3a58c21', 'Kavindu Silva', 'Kuliyapitiya', '0745263145', '200152400325', '2025-08-04 10:48:22.7342', '2025-08-04 10:48:22.7342', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2004-06-06');
INSERT INTO public.customer VALUES ('183dc79e-1b46-4531-948a-9072182795c8', 'Shehani Kahandawela', 'nagadeepa', '0378822345', '200421984523', '2025-08-07 13:31:34.591448', '2025-08-07 13:31:34.591448', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '0004-02-01');
INSERT INTO public.customer VALUES ('8a99b924-6b64-487d-974e-c44b5a0ca190', 'Malith Perera', 'Horana,Kaluthara', '07541236523', '200154623106', '2025-08-07 13:31:48.382933', '2025-08-07 13:31:48.382933', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-03-23');
INSERT INTO public.customer VALUES ('c5690609-4d4f-4f3e-a852-53acd69ac3d3', 'Sandali Kavya', 'Makandura', '0775423632', '200054122365', '2025-08-07 13:35:40.596114', '2025-08-07 13:35:40.596114', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2020-10-12');
INSERT INTO public.customer VALUES ('5371829a-831a-4c94-8f62-f50c6a3b9191', 'Yohan Fernando', 'Mulathiv', '0772212345', '200231982365', '2025-08-17 08:33:58.744699', '2025-08-17 08:33:58.744699', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2016-12-12');
INSERT INTO public.customer VALUES ('8515c62b-c3f0-4d94-955b-b63e6a8390d8', 'Didula Jayaweera', 'Mulathiv', '0231144345', '200612349923', '2025-08-17 08:35:17.556107', '2025-08-17 08:35:17.556107', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2015-12-11');
INSERT INTO public.customer VALUES ('b76a9d5c-3891-4491-9163-b03bc53f0141', 'Kamal Gune', 'Kilinochchi', '0342277834', '200012345678', '2025-08-17 08:38:49.506264', '2025-08-17 08:38:49.506264', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2000-12-03');
INSERT INTO public.customer VALUES ('f610dff2-6f8b-44e3-9af8-be31cacb3560', 'Kamal Silva', 'Negambo', '07145263254', '196154200332', '2025-08-17 08:40:50.934841', '2025-08-17 08:40:50.934841', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '1961-06-23');
INSERT INTO public.customer VALUES ('8547efd6-d5d5-4368-b560-fe08f9834a25', 'Sirimath ', 'Makandura, Kuliyapitiya', '0741256325', '1997524100365', '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '21997-02-10');
INSERT INTO public.customer VALUES ('5994c156-fcc4-4df3-bf6e-10905603941e', 'Nayana', 'Makandura, Kuliyapitiya', '075214463', '1999754200632', '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '1999-04-05');
INSERT INTO public.customer VALUES ('c77b68a3-2bdc-4c73-ae4c-1f0331757154', 'Saman Kumara', 'Nugegoda, Colombo ', '0754126356', '198541024148', '2025-09-05 10:33:30.449363', '2025-09-05 10:33:30.449363', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2019-10-10');
INSERT INTO public.customer VALUES ('07709cbf-2053-430c-a478-ae7cef5327a2', 'Roshan Fernando', 'Jaffna', '0883344283', '201034568822', '2025-09-10 15:02:09.020212', '2025-09-10 15:02:09.020212', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2010-12-12');
INSERT INTO public.customer VALUES ('08c15d5a-82f4-4b69-93de-37a76f2f7533', 'Nimal Appuhami', 'Jaffna', '0882233456', '199022334455', '2025-09-10 15:04:03.795948', '2025-09-10 15:04:03.795948', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '1960-11-11');
INSERT INTO public.customer VALUES ('c1f52f03-9b0e-4b5d-8ec7-7df36d52f2e8', 'Nimalawatheee', 'Jaffna', '0873324245', '196233445598', '2025-09-15 11:03:20.019027', '2025-09-15 11:03:20.019027', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '1962-02-05');
INSERT INTO public.customer VALUES ('6e7cb74e-b103-49e2-b3a7-ef9fabe4754b', 'Mahinda Deshapriya', 'Mulathiv', '0423344567', '196233445599', '2025-09-15 11:03:20.019027', '2025-09-15 11:03:20.019027', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '1962-02-08');
INSERT INTO public.customer VALUES ('8c72faa2-beb5-458d-80ac-dfff02cb4ce9', 'Mahinda Rajapakse', 'Kilinochchi', '0882345723', '200011334498', '2025-09-30 11:00:05.550255', '2025-09-30 11:00:05.550255', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2000-11-12');
INSERT INTO public.customer VALUES ('a32bd7d9-c3ca-4d17-8679-1aabd6634d37', 'Kamalhami', 'Mulathiv', '0882233456', '194522334456', '2025-10-01 12:00:47.112878', '2025-10-01 12:00:47.112878', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '1945-04-05');
INSERT INTO public.customer VALUES ('32f76078-4238-4898-95bd-e76a16ca8e3f', 'Kamal Gune', 'jaffna', '0372234845', '200011234567', '2025-10-20 12:00:38.78147', '2025-10-20 12:00:38.78147', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2000-02-01');


--
-- TOC entry 3796 (class 0 OID 31052)
-- Dependencies: 243
-- Data for Name: customer_login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.customer_login VALUES ('657f315a-9b6a-4c54-a3d1-b72fa645c7f5', '97da5431-f39a-43e5-b0cd-9d185327b6e6', 'mycustomer', '$2a$12$7gXkpFQmcoCPFx39ssSJb.FcJNK8opQzlLU5z5XcoYJEpcKZjWthm', '2025-09-19 02:18:40.386038', '2025-09-19 02:18:40.386038', '2025-09-19 02:18:40.386038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('bf23810f-9d8e-411a-b7f8-661766306774', '8f99e4a7-47ed-44ea-947f-89dae567a52c', 'customer70757', 'Bs3ewE5Q', '2025-09-24 17:50:34.479023', '2025-09-24 17:50:34.479023', '2025-09-24 17:50:34.479023', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('8c72a1ba-8252-4e9f-a0df-9d1491d8bcce', '4ab20e7b-e5c7-4331-b75d-2135c62c4ac7', 'customer86624', 'C6YMxxWN', '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('764f801e-4662-4c9f-928e-078ad141d743', '277ccc80-9a20-438e-93a9-459f041b145d', '12120703', '$2b$12$ut9A5rTddWH9A9Vna3XbeO4F0B6wTAClKaNaj0tsTRr60jnavCl26', '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('e22ba4a2-29d7-4edd-ab7d-d65b0eed2e76', '9609c225-a1dd-4eb6-b8c1-2908bd73cd3f', 'sangeethbanda9645', '$2b$12$r0xOa6G3zxQIJk8jYhCsNumvaxsRqZesSOXP8TW62elA3XpGZbYie', '2025-08-04 10:41:28.424569', '2025-08-04 10:41:28.424569', '2025-08-04 10:41:28.424569', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('45cf0d29-2725-49b2-aa21-892e6bc553c7', 'f848f8ae-9948-4406-a017-21c2ba879c8c', 'nimeshasandeepani0875', '$2b$12$z6amoCB7y.dckSUCLgb2weCwH60Fd.odmf864MRaG/hm5JWKCaVWy', '2025-08-04 10:43:46.657443', '2025-08-04 10:43:46.657443', '2025-08-04 10:43:46.657443', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('653457da-da53-44c2-bb81-8558a687fd1c', '5175ad1e-2b6e-4669-b46a-d0695abe67f5', 'malshadissanayaka3555', '$2b$12$Pv2vPTNgYdPbyR.MTcJ1IeqM4Jnndgoqb3BAlEOA6c/rrMzxp6FuG', '2025-08-04 10:45:04.650629', '2025-08-04 10:45:04.650629', '2025-08-04 10:45:04.650629', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('80479067-78f5-41f1-8c36-1ba734cde5d0', 'd2da339f-07f6-4914-aa0e-23a9d3a58c21', 'kavindusilva8408', '$2b$12$QXcTYa9vOH2iqi7xC2EW5.io3EcrkxMenEjq12GflTDwudCjxmS8i', '2025-08-04 10:48:22.7342', '2025-08-04 10:48:22.7342', '2025-08-04 10:48:22.7342', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('dcddf904-9417-4d36-afd2-76260320d61a', '183dc79e-1b46-4531-948a-9072182795c8', 'shehanikahandawela9517', '$2b$12$cbMc9EDCyr/WChAip/7oruP0bAn2o.mhK0GQsa4ugYfJqzHW79X7a', '2025-08-07 13:31:34.591448', '2025-08-07 13:31:34.591448', '2025-08-07 13:31:34.591448', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('098b70f2-71f7-40b7-9fbf-b14f92322c22', '8a99b924-6b64-487d-974e-c44b5a0ca190', 'malithperera7869', '$2b$12$ACVP4/OLQ8yeGvVPtWBxy..Twh16Nf4hv/tTJXbVSyBtkBc4KedmW', '2025-08-07 13:31:48.382933', '2025-08-07 13:31:48.382933', '2025-08-07 13:31:48.382933', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('f08ee97c-7e3d-4d67-8697-7317c179bcc3', 'c5690609-4d4f-4f3e-a852-53acd69ac3d3', 'sandalikavya3107', '$2b$12$069IAoc2UD9Xl6LGV0vKAuFCKQRWfQufg2zZxIKBjSt5xKKuiuJjW', '2025-08-07 13:35:40.596114', '2025-08-07 13:35:40.596114', '2025-08-07 13:35:40.596114', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('8b8d3b21-eba5-444c-8b83-feeb9d38ef3e', '5371829a-831a-4c94-8f62-f50c6a3b9191', 'yohanfernando6251', '$2b$12$cdfXHOSVphadgJmEcmk9tOucS.1mSRtpkryNiGaXT0YN8O7mBmstq', '2025-08-17 08:33:58.744699', '2025-08-17 08:33:58.744699', '2025-08-17 08:33:58.744699', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('477b2a4a-73fe-4c96-9e74-4b36ce2809ba', '8515c62b-c3f0-4d94-955b-b63e6a8390d8', 'didulajayaweera5788', '$2b$12$UiJ3bsxs85Pq4YL97YENAOouYO94mNOM/uMfqvyD0C/khiCWURGIC', '2025-08-17 08:35:17.556107', '2025-08-17 08:35:17.556107', '2025-08-17 08:35:17.556107', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('c966381b-0d87-4b5c-854a-8becde8112be', 'b76a9d5c-3891-4491-9163-b03bc53f0141', 'kamalgune2118', '$2b$12$bIHUV50iDsFVspDTwkJDpuQ21O85U.QhPuGIIv2pA3CKsK3WFd4pG', '2025-08-17 08:38:49.506264', '2025-08-17 08:38:49.506264', '2025-08-17 08:38:49.506264', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('8dc1444a-e622-4d07-b336-93b72b38deb9', 'f610dff2-6f8b-44e3-9af8-be31cacb3560', 'kamalsilva7730', '$2b$12$PYcNgqALKQBr5OWPkGgbW.F8tKzzQFey/944UnThdEGwKq747CbGK', '2025-08-17 08:40:50.934841', '2025-08-17 08:40:50.934841', '2025-08-17 08:40:50.934841', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('87a86e18-6229-43d2-8796-f9f554667847', '8547efd6-d5d5-4368-b560-fe08f9834a25', 'sirimath1568', '$2b$12$RSkZS4vUvjmc96.ePuduWeLWdNIqoDi6kqFzGQz4tvJniwyROj5Si', '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('0eaefb8b-0ad2-4a11-9076-3f70d35b9364', '5994c156-fcc4-4df3-bf6e-10905603941e', 'nayana8753', '$2b$12$R1zzQw1AO8GMXkiSrK43POf6gt3PxuufpTms44B4gscXk6.CJft8q', '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '2025-09-01 08:31:11.635135', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('f1979452-d8a9-499d-94a5-dfabdbbd2eed', 'c77b68a3-2bdc-4c73-ae4c-1f0331757154', 'samankumara9746', '$2b$12$yUfCfV8aaetmLS.EVhcP4.Vi2J0TUHTYAFNNWjH1qlJoR//vTTZn6', '2025-09-05 10:33:30.449363', '2025-09-05 10:33:30.449363', '2025-09-05 10:33:30.449363', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.customer_login VALUES ('027c7a3e-46ce-4429-a1bd-6cbaa6a75975', '07709cbf-2053-430c-a478-ae7cef5327a2', 'roshanfernando1323', '$2b$12$QWku/p0v7BMefJy8wpHUvO1JYXXb0wy.74pFpzdgqCADZELJTyqZi', '2025-09-10 15:02:09.020212', '2025-09-10 15:02:09.020212', '2025-09-10 15:02:09.020212', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('413393dc-67fa-4945-92ff-362f57158c90', 'a32bd7d9-c3ca-4d17-8679-1aabd6634d37', 'kamalhami3183', '$2b$12$o9IASRwK8furCPf/LHiW3Oqk/QPZRRsz575wfiLW291qY3LmW0Vga', '2025-10-01 12:00:47.112878', '2025-10-01 12:00:47.112878', '2025-10-01 12:00:47.112878', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('ff1dee91-4892-47f3-99fb-e800f4e185f2', '32f76078-4238-4898-95bd-e76a16ca8e3f', 'kamalgune6618', '$2b$12$kWDAUEvcUW6mzMQADFHeAeqaNJ44MXI9wOgOHtt6TTT2mNHXsRDg6', '2025-10-20 12:00:38.78147', '2025-10-20 12:00:38.78147', '2025-10-20 12:00:38.78147', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('37352e4f-bb1c-4452-b603-8a6e1c80e87f', 'ba15de27-893c-4915-bc20-6e56ab35b60b', 'meenakumari6688', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-08-04 10:37:07.826495', '2025-08-04 10:37:07.826495', '2025-10-23 08:19:18.083497', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('4776491a-e627-40f9-8c68-060532756e99', 'e1dd007e-8c4a-4607-b462-7239452c4d10', 'samankumara2464', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-08-04 10:38:17.380613', '2025-08-04 10:38:17.380613', '2025-10-23 08:19:18.08895', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('9fd4b57e-b66f-4db1-a416-fb8b3ce004db', '56850cc8-ac6d-46bf-89b7-34b3b38a20f2', 'himayabandara7317', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-08-04 10:43:46.657443', '2025-08-04 10:43:46.657443', '2025-10-23 08:19:18.090495', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('a882cbc5-a6d7-413d-8bf2-4807df35ab48', '08c15d5a-82f4-4b69-93de-37a76f2f7533', 'nimalappuhami7737', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-09-10 15:04:03.795948', '2025-09-10 15:04:03.795948', '2025-10-23 08:19:18.0918', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('8321c3ad-1579-4c51-a30c-bb9be1303571', 'c1f52f03-9b0e-4b5d-8ec7-7df36d52f2e8', 'nimalawatheee5444', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-09-15 11:03:20.019027', '2025-09-15 11:03:20.019027', '2025-10-23 08:19:18.093886', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('52596a79-1c05-441d-8faf-31e9c011bdd8', '6e7cb74e-b103-49e2-b3a7-ef9fabe4754b', 'mahindadeshapriya1758', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-09-15 11:03:20.019027', '2025-09-15 11:03:20.019027', '2025-10-23 08:19:18.095392', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');
INSERT INTO public.customer_login VALUES ('a13a331d-2483-4bf5-9ad6-d41bb9d84af4', '8c72faa2-beb5-458d-80ac-dfff02cb4ce9', 'mahindarajapakse7496', '$2y$10$UrnASXwK1nKG0JcXgrIs8eboSOG4ILG3T.ens9xCLIwcoqsda1TpW', '2025-09-30 11:00:05.550255', '2025-09-30 11:00:05.550255', '2025-10-23 08:19:18.096731', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7');


--
-- TOC entry 3797 (class 0 OID 31061)
-- Dependencies: 244
-- Data for Name: fd_plan; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fd_plan VALUES ('f6248a43-7311-4741-bf69-9e3628df3cee', 12, 14.00, '2025-09-18 13:37:13.906323', '2025-08-04 10:30:16.275648', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('fede8a9f-d3a5-4aee-a763-e43eae84397f', 36, 15.00, '2025-09-18 13:37:13.907726', '2025-08-04 10:30:16.277786', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('d693cf65-5f24-4820-aad1-7d5b7b9e86f5', 6, 13.00, '2025-08-04 10:31:32.737473', '2025-08-04 10:31:32.737473', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 20000);


--
-- TOC entry 3798 (class 0 OID 31068)
-- Dependencies: 245
-- Data for Name: fixed_deposit; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fixed_deposit VALUES ('ae3c7789-7290-4b86-9a93-043b62d83262', 0.000000000000, 'b646dd25-7775-417f-a216-30a84aa9c451', '2025-08-04 10:55:30.564301', '2026-08-04 10:55:30.564301', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-04 10:55:30.564301', '2025-08-17 08:46:35.359263', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 68983382, 'inactive', '2025-09-03');
INSERT INTO public.fixed_deposit VALUES ('fc98f9d8-cdc7-4c21-9a2e-859bdb24629f', 0.000000000000, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', '2025-08-04 10:53:02.758006', '2026-02-04 10:53:02.758006', 'd693cf65-5f24-4820-aad1-7d5b7b9e86f5', '2025-08-04 10:53:02.758006', '2025-08-27 08:34:13.678095', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 57699949, 'inactive', '2025-09-03');
INSERT INTO public.fixed_deposit VALUES ('53d16c90-6b7d-460c-ace8-a9bfc4425ac4', 0.000000000000, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', '2025-09-05 10:36:28.875612', '2026-09-05 10:36:28.875612', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-09-05 10:36:28.875612', '2025-09-05 10:37:16.65028', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 97265237, 'inactive', '2025-10-05');
INSERT INTO public.fixed_deposit VALUES ('43da858e-4220-47b5-8ed9-d43a212b1bb6', 299999.000000000000, '697a0943-3418-427b-9786-45b5c5066b71', '2025-09-01 08:36:29.090507', '2026-09-01 08:36:29.090507', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-09-01 08:36:29.090507', '2025-10-01 12:00:43.79928', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 28969810, 'active', '2025-10-31');
INSERT INTO public.fixed_deposit VALUES ('918fb3ed-4efb-4292-bb9c-d60d10f36a8b', 99998.000000000000, 'a6b1bdd7-e70e-4dd8-8621-397d69fb3300', '2025-10-05 12:00:47.856729', '2028-10-05 12:00:47.856729', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-10-05 12:00:47.856729', '2025-10-05 12:00:47.856729', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 26813609, 'active', '2025-11-04');
INSERT INTO public.fixed_deposit VALUES ('4280ea68-96f7-4356-bb39-2c6cfe8de223', 399999.000000000000, '1853d4ea-a229-4757-9a4c-f6f858351196', '2025-09-10 15:05:29.263694', '2026-09-10 15:05:29.263694', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-09-10 15:05:29.263694', '2025-10-10 12:00:10.270924', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 64474239, 'active', '2025-11-09');
INSERT INTO public.fixed_deposit VALUES ('740afff4-03de-4f0c-8f9d-e40aadbbbef5', 49999.000000000000, '30159eb0-328d-4cf2-84a3-d7f51040ed22', '2025-09-10 12:33:35.338774', '2026-03-10 12:33:35.338774', 'd693cf65-5f24-4820-aad1-7d5b7b9e86f5', '2025-09-10 12:33:35.338774', '2025-10-10 12:00:10.270924', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 10630536, 'active', '2025-11-09');
INSERT INTO public.fixed_deposit VALUES ('311d8492-d08f-473c-bfc5-53e76755ade2', 5000000.000000000000, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', '2025-09-10 15:06:25.913042', '2028-09-10 15:06:25.913042', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-09-10 15:06:25.913042', '2025-10-10 12:00:10.270924', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 28892515, 'active', '2025-11-09');
INSERT INTO public.fixed_deposit VALUES ('7b2a67e0-089a-4330-b95c-b6c354299bc5', 1000000.000000000000, '2effb977-c5cb-43cb-9c5e-7db80de361e4', '2025-09-15 11:04:35.869121', '2026-09-15 11:04:35.869121', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-09-15 11:04:35.869121', '2025-10-15 12:00:07.904117', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 93458513, 'active', '2025-11-14');
INSERT INTO public.fixed_deposit VALUES ('edda056b-5511-419e-9d42-751baf3d75bd', 800000.000000000000, '1dfe7946-7b05-4de1-8254-1528660baf18', '2025-08-17 08:31:53.82927', '2026-08-17 08:31:53.82927', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-17 08:31:53.82927', '2025-10-16 12:01:19.431619', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 56537165, 'active', '2025-11-15');
INSERT INTO public.fixed_deposit VALUES ('1e63ff92-b0f8-432c-a4af-2121eb1dd6cd', 120000.000000000000, '3aef91e8-f7b0-47a8-a03a-4c1770d74d30', '2025-08-17 08:41:43.769728', '2026-08-17 08:41:43.769728', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-17 08:41:43.769728', '2025-10-16 12:01:19.431619', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 15795036, 'active', '2025-11-15');
INSERT INTO public.fixed_deposit VALUES ('5d97ce3e-2824-414d-97b5-246de599f8d7', 600000.000000000000, '8f453f53-bf51-437c-b8a9-702b08caf92d', '2025-08-17 08:37:04.355603', '2028-08-17 08:37:04.355603', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-08-17 08:37:04.355603', '2025-10-16 12:01:19.431619', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 21395338, 'active', '2025-11-15');
INSERT INTO public.fixed_deposit VALUES ('c311104b-48be-44cb-940b-f9f8575da5f7', 199999.000000000000, '9f195429-65fc-48c0-8a22-3216088f897e', '2025-08-17 08:31:41.339773', '2028-08-17 08:31:41.339773', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-08-17 08:31:41.339773', '2025-10-16 12:01:19.431619', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 94769260, 'active', '2025-11-15');
INSERT INTO public.fixed_deposit VALUES ('909b7eb7-330c-4582-9b5e-728e9ee919a4', 100000.000000000000, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', '2025-08-17 08:41:56.329298', '2026-02-17 08:41:56.329298', 'd693cf65-5f24-4820-aad1-7d5b7b9e86f5', '2025-08-17 08:41:56.329298', '2025-10-16 12:01:19.431619', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 10832252, 'active', '2025-11-15');
INSERT INTO public.fixed_deposit VALUES ('4f8d73bf-016f-42b9-80da-8b6603da9b5d', 100000.000000000000, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', '2025-08-04 10:53:38.203207', '2026-08-04 10:53:38.203207', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-04 10:53:38.203207', '2025-10-03 12:01:10.850765', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 71876545, 'active', '2025-11-02');
INSERT INTO public.fixed_deposit VALUES ('43fff487-57bd-4cb7-8567-426e5f26997b', 200000.000000000000, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', '2025-08-04 10:49:54.170884', '2026-08-04 10:49:54.170884', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-04 10:49:54.170884', '2025-10-03 12:01:10.850765', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 63351599, 'active', '2025-11-02');
INSERT INTO public.fixed_deposit VALUES ('f1b2809d-8abf-4e99-8e78-0d0fc8ebf2b3', 399999.000000000000, 'd38f3e7a-9414-40e4-b62f-47019c16be6b', '2025-08-29 08:30:23.777358', '2028-08-29 08:30:23.777358', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-08-29 08:30:23.777358', '2025-09-28 12:01:06.107982', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 80741694, 'active', '2025-10-28');
INSERT INTO public.fixed_deposit VALUES ('2e609ce4-06ad-4281-b33a-7b71fa4d7a25', 229999.000000000000, '99280df3-2bad-4c61-b069-bf6144235552', '2025-08-31 08:30:04.259167', '2026-08-31 08:30:04.259167', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-31 08:30:04.259167', '2025-09-30 12:01:03.698862', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 56004431, 'active', '2025-10-30');
INSERT INTO public.fixed_deposit VALUES ('b6efdeb4-a637-4f17-bd18-dc2678c75146', 400000.000000000000, 'f4a8e8d5-92af-421d-a437-dce94fd12638', '2025-08-27 08:30:21.836043', '2026-08-27 08:30:21.836043', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-27 08:30:21.836043', '2025-09-26 14:45:06.944417', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 10915296, 'active', '2025-10-26');
INSERT INTO public.fixed_deposit VALUES ('ea328918-2ca8-4ffe-8f61-6ed4110aaec5', 100000.000000000000, 'a949c77a-bb3b-484f-9b3e-8d68a36deb87', '2025-08-27 08:37:53.929716', '2026-08-27 08:37:53.929716', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-08-27 08:37:53.929716', '2025-09-26 14:45:06.944417', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 13412211, 'active', '2025-10-26');
INSERT INTO public.fixed_deposit VALUES ('a08f90c9-1b17-4952-b907-fdeb35649165', 300000.000000000000, 'b79aefad-de0e-4387-84cb-7a1234ce4ce7', '2025-08-27 08:33:38.71221', '2028-08-27 08:33:38.71221', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-08-27 08:33:38.71221', '2025-09-26 14:45:06.944417', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 93664811, 'active', '2025-10-26');
INSERT INTO public.fixed_deposit VALUES ('816ce0c4-de62-4ac4-9d50-4446c54c4fc2', 200000.000000000000, '17c9a664-3b42-456e-95e4-4bd73353f0e0', '2025-08-27 08:30:21.300452', '2026-02-27 08:30:21.300452', 'd693cf65-5f24-4820-aad1-7d5b7b9e86f5', '2025-08-27 08:30:21.300452', '2025-09-26 14:45:06.944417', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 43639715, 'active', '2025-10-26');


--
-- TOC entry 3799 (class 0 OID 31082)
-- Dependencies: 246
-- Data for Name: login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.login VALUES ('ef0de396-9787-4c94-81b4-14b1e087fb51', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-09-18 07:01:09.926708', NULL, NULL);
INSERT INTO public.login VALUES ('97ac0c3a-f003-4f92-bae1-edce2a4b7406', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 07:18:25.922307', NULL, NULL);
INSERT INTO public.login VALUES ('7f26152e-ee50-4ea2-add4-5042e703a9f3', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 14:02:15.673806', NULL, NULL);
INSERT INTO public.login VALUES ('c7a75b83-7373-4eab-940d-ef69e5ed44e2', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 00:12:51.793619', NULL, NULL);
INSERT INTO public.login VALUES ('24cd39be-cecf-48bb-99c5-fb23ce166393', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 00:13:31.50498', NULL, NULL);
INSERT INTO public.login VALUES ('956aaf49-ae2a-4947-8240-b76fc1485a9a', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 00:19:04.878591', NULL, NULL);
INSERT INTO public.login VALUES ('a00747be-3c10-495b-b5e2-62ffcd65cd69', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 00:21:39.068569', NULL, NULL);
INSERT INTO public.login VALUES ('088d8aab-4a05-46bb-a680-427742fac103', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 08:29:33.647934', NULL, NULL);
INSERT INTO public.login VALUES ('d8704f1d-c2b9-4bf3-bfd3-e5e7c6324fa7', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 08:36:07.238748', NULL, NULL);
INSERT INTO public.login VALUES ('661ac81f-7f8d-4391-8e5a-53ef9f88be78', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 08:38:45.676682', NULL, NULL);
INSERT INTO public.login VALUES ('98f5e1fc-685d-4d91-a2a7-639618287f22', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 08:38:45.830166', NULL, NULL);
INSERT INTO public.login VALUES ('08081e37-51c7-4b7b-abc3-fa770d7f0fac', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:12:44.162598', NULL, NULL);
INSERT INTO public.login VALUES ('8b4f58a9-4aa7-49bb-a323-da66ae8e9a8c', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:15:19.051326', NULL, NULL);
INSERT INTO public.login VALUES ('4ddb70fe-01ab-4de1-9496-0ff91a87cf3c', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:26:09.18484', NULL, NULL);
INSERT INTO public.login VALUES ('da1843dc-2286-4468-a6f7-9ac3a618a47f', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:28:10.791807', NULL, NULL);
INSERT INTO public.login VALUES ('798891a8-e72c-4331-a8d6-99b6107aafbe', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:28:51.849261', NULL, NULL);
INSERT INTO public.login VALUES ('86a8e9d8-d08e-4be1-b992-4af061423aa2', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:30:11.104932', NULL, NULL);
INSERT INTO public.login VALUES ('f91d0d08-2116-4d84-b710-32d2011b0115', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:30:18.18191', NULL, NULL);
INSERT INTO public.login VALUES ('0af891cb-de3d-4748-aeda-449e0dc84902', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:33:49.144016', NULL, NULL);
INSERT INTO public.login VALUES ('66eaf027-57a9-4a88-b9fc-a5a27ccd1e96', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:34:04.460221', NULL, NULL);
INSERT INTO public.login VALUES ('e404055a-44ff-4f4c-87ea-bb4e968741ca', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:34:30.289995', NULL, NULL);
INSERT INTO public.login VALUES ('0566b1e1-9e1f-4f6f-a3f2-d4a0d7dbc1b6', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:39:29.91845', NULL, NULL);
INSERT INTO public.login VALUES ('c0b72674-98d4-4e46-867f-a0123fc78c6e', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:40:00.31766', NULL, NULL);
INSERT INTO public.login VALUES ('5c2da375-a53e-4de7-b2e1-efb7c828370f', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:41:12.982784', NULL, NULL);
INSERT INTO public.login VALUES ('222ca744-5236-4286-8dd3-e4b4483a0b05', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:41:26.518716', NULL, NULL);
INSERT INTO public.login VALUES ('25f7bc81-b06f-4a98-9275-0d884513e704', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 09:43:22.662356', NULL, NULL);
INSERT INTO public.login VALUES ('ee36c8d4-e24d-403f-a07e-5bb803939f34', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:14:56.642084', NULL, NULL);
INSERT INTO public.login VALUES ('332f9250-1352-430d-9859-6b6c6e76872f', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:15:16.806745', NULL, NULL);
INSERT INTO public.login VALUES ('104dc9f0-339c-4901-b0bd-2149ad5b5305', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:18:53.236694', NULL, NULL);
INSERT INTO public.login VALUES ('019fb882-1814-4f74-8627-0a2baf5fceaa', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:20:50.930569', NULL, NULL);
INSERT INTO public.login VALUES ('a7a73d01-fce9-4950-b21d-9b90cbdf41ab', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:21:08.494516', NULL, NULL);
INSERT INTO public.login VALUES ('851db057-88fd-4022-bfe3-5004634b6e31', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:24:36.974369', NULL, NULL);
INSERT INTO public.login VALUES ('21ca13ef-808c-4083-8338-e66a9aa84662', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 10:24:37.119049', NULL, NULL);
INSERT INTO public.login VALUES ('247e66d9-579b-495a-b8a3-9ee7e08ed9d4', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 11:58:36.805702', NULL, NULL);
INSERT INTO public.login VALUES ('43d8f319-0a0e-4141-9846-558f41d7ca9e', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:32:14.457167', NULL, NULL);
INSERT INTO public.login VALUES ('be85ca9c-0233-46ed-9df5-1a4dbdc6765b', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:42:22.106468', NULL, NULL);
INSERT INTO public.login VALUES ('239cde64-84c9-46af-9129-c235d8983b79', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:45:53.248993', NULL, NULL);
INSERT INTO public.login VALUES ('f0505621-71d7-4471-bed2-723ffaf635b5', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:51:19.637397', NULL, NULL);
INSERT INTO public.login VALUES ('0617d2e6-1141-4e66-967c-e4fe6f6bba68', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:52:08.664102', NULL, NULL);
INSERT INTO public.login VALUES ('053b92c7-470a-4994-8e92-a42a441a752b', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:54:08.894736', NULL, NULL);
INSERT INTO public.login VALUES ('227bd0d4-2529-4a9f-8f54-4aa3f1698f67', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 12:55:40.120396', NULL, NULL);
INSERT INTO public.login VALUES ('52dd694a-bed1-4043-b29a-22d7f016a77d', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 13:21:08.872421', NULL, NULL);
INSERT INTO public.login VALUES ('7178ca92-9a44-4174-a701-0a17139d22fa', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 14:55:55.070887', NULL, NULL);
INSERT INTO public.login VALUES ('0f754dc9-5060-489f-a928-42c4cd36f21d', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 15:02:07.285389', NULL, NULL);
INSERT INTO public.login VALUES ('b4b9a587-da46-452f-bf9a-94a93df86285', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 15:02:34.493569', NULL, NULL);
INSERT INTO public.login VALUES ('916333ac-8e5d-4f42-811a-ce5b5a95231c', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-22 15:04:55.165556', NULL, NULL);
INSERT INTO public.login VALUES ('9b6a88bd-8e32-47d0-8c47-1a5f024fc1e2', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:05:23.591901', NULL, NULL);
INSERT INTO public.login VALUES ('0bdf145d-014b-402d-9bbc-298d2530df75', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:08:08.734019', NULL, NULL);
INSERT INTO public.login VALUES ('f0b725c9-12a6-473c-8aae-5ea3c8291dd3', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:15:51.918282', NULL, NULL);
INSERT INTO public.login VALUES ('400d52ba-8f6b-4183-9411-adaddf8f7ceb', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:25:24.529113', NULL, NULL);
INSERT INTO public.login VALUES ('8544fc12-c262-427b-ae83-b813268dc5ae', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:29:03.255206', NULL, NULL);
INSERT INTO public.login VALUES ('295fb3ef-1c47-4efb-a9bd-bba3c8116a8d', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:30:35.183195', NULL, NULL);
INSERT INTO public.login VALUES ('c2abbfa0-29d3-4b46-9d77-398f3ac769b0', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:31:04.780978', NULL, NULL);
INSERT INTO public.login VALUES ('75426396-5a2e-4840-a21d-d38138a1ce3c', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:34:51.942397', NULL, NULL);
INSERT INTO public.login VALUES ('1c30921d-471c-4cd8-a62a-d646eaa03e5d', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:39:28.159649', NULL, NULL);
INSERT INTO public.login VALUES ('6d88e1e9-32b5-402b-839f-090fc79e78d3', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:48:10.59552', NULL, NULL);
INSERT INTO public.login VALUES ('e5b97c88-c51a-4125-b385-090fa9337142', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 16:53:14.776179', NULL, NULL);
INSERT INTO public.login VALUES ('40f6041c-2230-4496-8762-ed503ac08c1a', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 18:22:57.789061', NULL, NULL);
INSERT INTO public.login VALUES ('44c92e5a-dfc7-43b4-9177-f95ae6ce7116', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 18:27:18.47859', NULL, NULL);
INSERT INTO public.login VALUES ('130244f1-0789-4005-a18a-4aa242ec470e', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 18:58:43.309883', NULL, NULL);
INSERT INTO public.login VALUES ('0f71786b-635b-4f3d-b286-a531b2f46d7c', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 19:03:40.990556', NULL, NULL);
INSERT INTO public.login VALUES ('3f7ccca4-43f6-45c7-aeeb-31d7dfe7b0ea', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 19:06:33.792775', NULL, NULL);
INSERT INTO public.login VALUES ('12d5fba8-fc25-4a8f-a072-dcdb89f0c245', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 19:09:20.209367', NULL, NULL);
INSERT INTO public.login VALUES ('11c0f672-6c5e-4c53-8bc0-ece376e83bce', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-23 19:18:56.242158', NULL, NULL);
INSERT INTO public.login VALUES ('5804e080-cffa-4572-89f0-292a1467ff9a', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-24 14:52:03.556122', NULL, NULL);
INSERT INTO public.login VALUES ('dfedeb1d-f7c7-4a09-9749-6c8e60170ada', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-09-24 14:56:02.517613', NULL, NULL);
INSERT INTO public.login VALUES ('e86da0fb-65a0-42bb-a838-3b68dcf94d39', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-09-24 16:36:50.58681', NULL, NULL);
INSERT INTO public.login VALUES ('7b14fdfc-bf21-4271-baf2-e88d1e7dc97a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-09-24 16:57:29.653583', NULL, NULL);
INSERT INTO public.login VALUES ('3649a840-c62a-4913-97c7-0e5673de5853', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-09-24 17:28:12.593984', NULL, NULL);
INSERT INTO public.login VALUES ('16467b5e-a0b2-416c-b755-500ad1bf9c4a', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-25 09:00:08.90512', NULL, NULL);
INSERT INTO public.login VALUES ('9f5c7490-d01b-4406-82d3-a0553d74dc3b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-09-25 23:38:09.242012', NULL, NULL);
INSERT INTO public.login VALUES ('39b873e9-37c6-4ea3-bb4b-71c83ab56700', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-01 19:03:50.948127', NULL, NULL);
INSERT INTO public.login VALUES ('7afc3e67-93e1-4423-92ca-cb52048e9edf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-01 19:22:27.325854', NULL, NULL);
INSERT INTO public.login VALUES ('cf8d3806-e790-4708-8b55-32b58cdce2af', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-01 20:48:39.472154', NULL, NULL);
INSERT INTO public.login VALUES ('b16487bf-83eb-4724-9d6a-a595655ad9f0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-02 06:04:38.633697', NULL, NULL);
INSERT INTO public.login VALUES ('40b64c3f-7444-4b73-ba56-ba6204e6a763', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-02 06:41:27.485645', NULL, NULL);
INSERT INTO public.login VALUES ('d1a2e970-1de4-4504-8f17-1f7132422c36', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-02 06:45:00.681053', NULL, NULL);
INSERT INTO public.login VALUES ('bf4c1b21-52cd-43b8-8958-83f1f1c93eb2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 17:24:01.788872', NULL, NULL);
INSERT INTO public.login VALUES ('82313efc-c0dd-419f-8b1d-a4059dd28a1a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 22:25:06.250304', NULL, NULL);
INSERT INTO public.login VALUES ('118262bb-ebca-44b2-ac3d-d978e5ce71b7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 05:56:39.152811', NULL, NULL);
INSERT INTO public.login VALUES ('b5836284-c13c-4211-b392-08be9d0d5f6c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 10:17:10.189739', NULL, NULL);
INSERT INTO public.login VALUES ('f69a52cd-d0bc-4186-b4a4-5cdc868433c8', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 11:03:58.484246', NULL, NULL);
INSERT INTO public.login VALUES ('838f8d6c-651d-440f-81ef-feca461018dd', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 11:34:57.924429', NULL, NULL);
INSERT INTO public.login VALUES ('6f992a81-64ab-48f0-a88b-042e5f07e91c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 12:07:27.888021', NULL, NULL);
INSERT INTO public.login VALUES ('7989ac14-ba26-4500-95dd-5b87bc980473', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 12:08:08.701404', NULL, NULL);
INSERT INTO public.login VALUES ('0d2b4561-e119-4647-b6a2-d7c8795a2467', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:17:43.632612', NULL, NULL);
INSERT INTO public.login VALUES ('402e7e85-1675-4b66-a0c4-3dbf2658ba5a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:20:32.365861', NULL, NULL);
INSERT INTO public.login VALUES ('414f695d-6727-4d09-8b38-67ba4e7234f9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:32:10.925497', NULL, NULL);
INSERT INTO public.login VALUES ('99eeccc2-9785-440a-b9d7-41e02e6ba8e6', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:35:32.52417', NULL, NULL);
INSERT INTO public.login VALUES ('6c934002-3049-4f5d-905f-0b6f715fb5dc', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:37:29.370267', NULL, NULL);
INSERT INTO public.login VALUES ('f749a673-1fa5-4967-9d95-ae813adffd11', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:39:04.156067', NULL, NULL);
INSERT INTO public.login VALUES ('ff0d5fbd-2dd1-45af-b978-ac5868104474', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:44:54.174922', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('3c018b5f-d975-430f-836b-ea1e8814d754', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 16:48:42.312328', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('6ca6118a-3520-4632-9acb-471a7175d5a8', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 17:09:54.081701', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b9023887-0a24-44a2-b29e-aa6bfffe0fee', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-04 17:37:47.821888', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('2b20ed8d-99ab-4f04-8735-1347db6f4119', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-04 17:38:14.554209', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('0e3df43f-fd25-4a8c-a9b4-d41400ce7e0e', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-04 21:13:58.368135', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('162ff392-e17c-4a25-ba2a-084f03ecf428', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 21:32:11.370486', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b54d7379-552b-4cfe-ac89-f10c5a72784c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-04 21:32:42.408788', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('02c7ea46-f016-4dd1-bfcf-19d440f54f14', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-05 17:07:25.342349', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a164393a-b627-4a20-8ea9-29d309ef3311', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-05 18:44:43.226048', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('6d1ef954-7734-4753-b661-fc840ebb86d1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-05 19:46:46.069177', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('0217acc3-bcac-49b9-9412-5a4225b7c483', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-06 17:26:08.353936', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a0edb48a-c6a2-459a-8359-c9382d2719a5', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-06 17:45:24.479392', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('9c2dd9a9-b97e-40db-95af-32106f79e5d3', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-06 17:46:16.843008', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('6a8ddd26-0e0b-4769-ab39-03f4e3f2d262', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-06 20:29:23.629078', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('bc25e75a-2293-412f-b663-06246d170f2b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-06 20:33:30.390085', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('577fc37e-f167-4b80-8b25-ef625921923c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-09 10:22:48.936316', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('495a9e2b-aefa-4f8a-a342-7cdc61ba75cb', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-09 10:52:45.096285', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0');
INSERT INTO public.login VALUES ('b5ab3913-8864-4ef0-be86-1ea18ae516bc', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 03:32:08.168368', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('573c2b31-427b-4600-9842-09562f4c3ad9', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-14 08:36:32.885277', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('2ab6c280-9b92-48d9-b52d-05e60ee56097', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 11:21:28.46134', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a77a6260-4337-4d46-b604-a0fed6c63183', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 11:32:38.88962', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('376a87dd-9272-4c84-b6bf-0a9c036b8715', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 12:14:15.066008', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('ba1095ad-5b81-4e18-8668-3173fac8fc5d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 12:42:18.777863', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('4a4e28f6-b2e4-46c2-9eaa-ef42523de9e1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 13:14:40.408423', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('c0daa3e8-3d36-420e-8fa7-1e220acc13e4', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 15:29:30.634518', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('526c4621-e137-4b5f-a1bb-32642c2cdbdd', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 15:41:26.075832', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0');
INSERT INTO public.login VALUES ('debb5776-648c-4e63-b27b-e84fae23152f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 15:44:15.339444', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0');
INSERT INTO public.login VALUES ('cd5e29f6-40ca-4091-b964-dd8a850ec74e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 16:34:13.631337', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0');
INSERT INTO public.login VALUES ('b73dc0f4-2ccc-4d32-b603-5ee8882642a0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 20:19:34.370909', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('f7a93a90-967c-4f96-810f-413c7d0e3d9d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 20:23:48.776474', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b54fa0c2-5047-4f70-957d-10560b8d9d2f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-14 20:40:43.352313', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('01b8d76e-06f6-4462-ba0c-3c483d98afcf', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-15 01:28:36.603633', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('0bc19725-c9dd-4bcc-b1b4-bfca3a6fcb40', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-15 01:28:36.843556', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('9ac366ac-5e1f-45c9-a8d4-6d1e43cb4166', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 01:46:34.92432', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('86ff1d97-0543-4dcc-8a08-3e0e80092a97', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-15 02:09:56.805507', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('08eb049f-e8bb-4771-b10a-1927587d6ace', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-15 02:41:46.827468', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('4c0f1ce8-b243-4351-8747-4b6818ad6cb7', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-15 03:20:37.193821', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('8374be6b-603f-4fec-847e-0bb2b0501eb0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 03:20:49.288983', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('ecd31169-11e4-4c91-bfd9-eeea7312eefe', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-15 09:20:14.457297', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('d2750cbe-8c46-4081-83b6-1686ea90214d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 09:21:39.748747', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('4a062f26-2bcd-46f7-909f-da9bb9552b70', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 10:37:26.838398', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('fe93e698-81bb-4720-949d-1a1f0fad0ba4', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 11:35:55.234374', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('20f02a4b-0d12-4fce-8cd5-b98b50a16b18', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 11:37:33.802464', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('6ac89208-726a-4c8a-a5d8-5a379ff066c3', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 12:35:35.100984', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a9a173e7-f049-4338-b159-4d8989c4f848', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 12:54:27.557912', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0');
INSERT INTO public.login VALUES ('ef3dcb25-cf45-44aa-8f92-4287753d896b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 13:33:44.349391', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('bb9a680c-2f30-4934-beb9-c9dbc433149d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 14:05:27.373453', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a09bd9bd-14cb-40b6-9d9f-db40bb29283c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 21:03:42.458662', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('6c2c3b38-aba5-4a9e-93dd-b7bc67c54bdf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 21:29:38.683843', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('11e47834-f716-4c28-8102-2e05e1f98f76', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 22:39:10.540905', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('883e681e-9f45-4ea9-ad00-bf5b6c11389f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 22:55:20.890768', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('3e3cc0e4-05cd-4447-8e71-2ab197a5c34d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-15 23:09:37.905958', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('f59d64cd-e668-4620-ad66-54a3484037ca', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 00:58:15.826918', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('99543a4b-3e56-4077-abe6-f6c1e37b840c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 01:08:53.208566', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('20e44fe5-b28e-4e9c-ba5d-06fc35189cf3', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 01:22:26.568711', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b136e0e9-f746-4d2f-95f5-30a3051e47d9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 01:23:38.747338', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('35869520-47f6-4c6e-b357-2d39b697cd27', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 01:36:04.168142', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('e8a3f5fe-9b86-4cda-834a-4894e0482ba6', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 03:14:24.633214', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('81dd463f-462c-46d6-90ae-11d60e667f17', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 03:18:09.067469', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('158eecea-829c-4931-b40e-f013f5d50edf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-16 08:29:20.929788', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('d541d5cb-fb08-495d-ab15-ab6460b71b6a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 01:31:34.308263', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('9a7c17bd-ebe6-48e5-9533-9318e7b1b434', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 01:42:33.531005', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('faa3f78d-b2cf-413a-b817-5a4836a5aba0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 02:19:30.911736', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('35d23922-ae6b-4840-9b97-7d13e9015db0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 09:43:32.520085', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('c6edaa23-2934-4119-b14e-17e685e437aa', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 10:08:16.966141', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('9bbc333b-2ffd-4861-9566-75f1f6278e9b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 11:58:46.278176', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('30c0fccb-7818-44d3-a16e-5cda76329ef9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 13:35:23.386825', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('4ca7ebec-bf52-4076-936d-92ec05e90ac2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 15:11:10.339487', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('10f77864-b20d-4bae-af3b-97bd163412c6', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 17:29:54.616702', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('9d7913c9-5d8d-4ac0-8aed-f944df93ab4d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 19:33:50.349896', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b0bc51a9-bcc3-45a1-845e-dbacca860a7c', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-17 21:27:47.13728', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('46cd530e-4a9a-44b0-a879-758d79e9412f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 22:36:21.8575', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('dc3b7253-276e-42d6-b6db-0315700f4ffd', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-17 23:30:54.447702', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('523233c0-d6f7-403a-904d-d41dc6b63816', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 01:20:00.574949', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('f518e0cd-a81d-4b01-804c-13715e3e4424', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 07:40:52.235572', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('dee8904b-e13b-4d0f-a160-7bafb4672164', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-18 07:45:51.97352', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('47767212-b2a8-4fb1-97ca-e8f7559fae61', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 00:42:32.530073', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('8c308fa1-5b8f-404d-8338-5c3c061c09c8', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 01:08:06.541976', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b93aeae6-63d6-4508-ab37-fcf62a8004fa', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 02:36:16.782799', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('587eff92-8637-4645-baa4-5e7c071368b5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 09:03:48.799935', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('51e9ea6c-fa20-48ed-bcd8-410c91e77f7d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 09:09:01.57057', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('eb52fb48-decb-4a06-8fdf-97cd1eadaadb', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 12:58:42.674548', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('6466583d-bf56-44dd-99d8-017aec45f461', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 13:19:15.349616', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('1a6c9221-d4b8-405a-b05e-0bf0418d6a96', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 14:10:32.142994', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('79ba8769-1694-4d69-9d07-84cc77439f29', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 16:08:42.474298', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('708d8f77-15b3-4b37-b2d8-0d7410030603', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:05:17.138477', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('675e1098-7cf2-4ed2-ae7f-b277f690299f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:45:42.669199', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('267fd48a-83a9-47e7-b3a9-20ebcef0898e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 17:53:41.919077', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('aa8d1f74-13e7-46e8-8a9a-b07d041ad917', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-20 21:56:52.349307', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('af06005d-5ec4-42b0-8d88-c8c28487dbc2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 06:31:01.972477', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('04f0352f-0191-4940-bb7a-33ee6a6474ee', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 09:38:14.110293', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('215f9f9b-b9f7-442a-a6d3-a4bd5f1d136e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 09:42:02.54132', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('79cdfb0c-3380-48b2-9f9a-ca715c082bc2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 09:44:41.878267', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('532c5f81-6ee0-4d6c-a311-19a69b39201e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 11:53:07.100742', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('5d835f5f-7483-455f-80c5-15321125258f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 14:34:23.947112', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('22f4560f-861d-45ad-b8d5-d7bf9022ff41', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-21 18:13:11.480472', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('1ff52862-8247-4b04-8587-05af6758653f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-22 10:35:58.914107', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('46ca346a-1cb0-4afa-9a1b-736e48308cee', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-22 11:48:28.577049', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('86bafbcc-98e2-4660-acd9-bcb8dbe233b8', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-22 22:50:19.387104', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('7b998303-ee61-43e7-8804-8b59511d3a9a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-22 23:01:18.717479', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('bb212aa6-a917-4671-adf4-dd81792a04e1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-22 23:01:39.223434', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('3003f7e2-00ff-4582-8731-669593be4417', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-22 23:02:23.72222', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('1892e742-be86-4deb-8655-25167a20568f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:04:43.70874', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('b9249846-6d88-49ff-a62b-966d6607f003', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:04:55.131238', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('a5c228c2-05e5-489b-a733-aa4a1a5777c0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:08:22.872436', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('577f9b84-959d-460b-804d-e4d6f035c97b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:08:23.498757', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('f4aa262a-1577-40d8-9a64-fa0043135910', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:08:41.397408', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('f24b166e-1cfa-4a5a-a18f-c347d537ca74', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:09:10.964368', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('5c645fe7-8ef2-45de-8aeb-998e8bf51947', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:10:11.149336', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('a8f5593a-aeab-433e-8de6-6dd9b6a788eb', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:10:55.507096', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('51b63e20-2df5-4579-8bd1-1a71bc7b9d42', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:11:21.550653', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('b386d62d-72dd-4f8c-a0ce-06c258709310', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-03 10:11:37.13249', '10.10.13.225', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('b3bc8879-2e01-4839-a738-2d8556ae0958', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:31:28.166614', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('6ad1c945-f16c-469d-acab-5f53a36737a9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:32:39.381073', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.141 Safari/537.36');
INSERT INTO public.login VALUES ('490c69d3-8152-4cb3-9f8c-457caac14f0a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:33:34.207215', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('fc89d276-0466-4863-8495-ac500907cfd9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:34:37.856897', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('6b9e0817-98ef-45f4-b9cd-4dc9d39efb01', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:35:29.142094', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('9c8b59c4-c3db-4cf5-80f8-6be23f51f3c7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:35:41.942208', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('efd77ba7-135d-416c-b9f3-27703a62c96f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:36:26.071064', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('45f0fc1b-6f6b-4248-a70a-a9b62aba79c2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:36:40.003121', '10.10.13.225', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('55404dff-dcbd-4e5d-be8d-5371852c6400', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-08-04 10:36:50.966222', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('78c87664-9c30-44e0-8634-b491a64eb189', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:37:25.875191', '10.10.13.225', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('98664269-6168-42b3-840f-ad41174e29c5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:37:40.650115', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('391bdd5f-74f3-4b85-9839-808e64264858', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:38:19.114161', '10.10.13.225', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('6e4305e4-9fe1-422f-a709-2c99f39c17ca', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:38:34.191191', '10.10.13.225', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('d6bb1208-9b1d-433f-9594-cbe13973207f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:39:48.322458', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('05e3976c-2d08-4653-a46d-7d6aa0f63ee6', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:40:26.35144', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('418eb227-50ef-434d-833d-d66a720e19c5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:42:52.37654', '10.10.13.225', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('60736b59-ce1a-4f94-8781-0f05e6b01026', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:58:15.005409', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('595a15ee-336d-4590-b1f1-8f22fffcbae8', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:58:32.587714', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('375cf07c-391f-4344-ab46-4b20e1a6be20', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-08-04 10:59:08.631684', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('559000df-72d6-4a82-be97-b05bf9a93d47', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-08-04 10:59:18.913246', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('c863c8ac-de73-42c7-84fb-67a3c74889e3', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:59:29.77927', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('453397a8-e162-45ea-a5cd-92333740ae6e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:59:48.641527', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('1d8166c0-10fd-4591-a460-2f08ca5b11ad', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:00:09.651217', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('c9efcea1-f8ec-4775-a6d2-49df799dbdba', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:00:51.270235', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('468d6aaa-fad8-46bf-97ee-a8a5015908ca', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:00:59.49351', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('b4def442-c596-44ba-a6c2-64d38f2204bf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:01:02.76845', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('0a6a5482-432b-403e-a252-b23c77a5dc83', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:05:33.141613', '10.42.0.151', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('f69cbdcf-72f3-474d-8acf-4b6fe3373511', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:06:46.175532', '10.42.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('33ae5568-a3f1-45a2-9c27-268e1d8ae232', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:07:15.70718', '10.42.0.151', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('9e5cb52d-bdbb-44cb-8800-210d00291b7d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:08:19.722009', '10.42.0.175', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36');
INSERT INTO public.login VALUES ('f73f0b68-4142-40e8-b7de-c76be1a4fe73', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:11:01.27753', '10.42.0.159', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('ca7f7431-b492-4b9d-ad2e-8f4744a94435', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 11:11:29.43367', '10.42.0.159', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('1578ce28-ee89-41f2-bc1c-cedcb39c8edd', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:31:02.942778', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('9b92c304-ae88-424d-96b9-8b1f5a2a95c2', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2025-08-04 10:34:08.553963', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('2e4c0937-b7e0-406f-a4ff-7676c11251a2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:34:41.924573', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('9da662aa-33b5-4367-beb4-306cbdfcec7b', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2025-08-04 10:35:49.328409', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('4355df04-9851-4a6f-a763-7a114ad70ed6', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-08-04 10:37:02.377584', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('d7dbc539-0ba1-49ff-b577-9449794ebec1', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-08-04 10:37:45.520368', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('fa92255d-7705-4e0f-bb17-ae69c86e31af', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-08-04 10:51:57.454701', '10.10.2.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('cfb30eb0-e326-4bd8-93c6-22732cb0a817', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-04 10:52:09.157681', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('21b2775a-78a1-4946-9ee0-f9b3682d12f7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2025-08-04 10:54:39.954362', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36');
INSERT INTO public.login VALUES ('27d1bfe4-b9bb-4102-8b4f-9e89972dc839', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-08-05 12:31:25.001847', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('8a180c47-085a-46c8-9ec6-aa2b6819dcbf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-09-05 10:31:32.54737', '10.10.30.86', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('255fceef-8503-40b3-9dc9-b620962c4c1b', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '2025-09-05 10:37:51.342819', '10.10.18.84', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0');
INSERT INTO public.login VALUES ('274b71e5-c4fa-418a-957a-8af011b275b0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-22 23:27:47.449125', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('b6b8735c-8e13-4c2a-8d8b-e708a68ab716', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-10-23 08:17:22.791029', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('056ecfa7-45a0-447b-a014-04ba15d8cf63', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-23 11:04:48.641092', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0');
INSERT INTO public.login VALUES ('c5a00cef-b45e-468f-afbb-8d36d904ec01', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-23 11:10:20.540125', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('76e00b3b-5ad7-45bd-b614-3bf0fdcf6984', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-23 11:19:50.921655', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('28b03b7c-92a8-449f-97d8-f76ffe27075e', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:27:09.247148', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a5e9b530-76ba-4be8-93d1-6656a5225e52', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-23 11:27:43.695914', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('bc5a57f5-4b7a-4815-8d83-c13231e7ed71', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:29:00.382364', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('80c8e25d-da1b-4b18-930b-4f1cdf697399', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:29:33.115473', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('a753779f-9c17-4a96-a89b-8e47a2d68c09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:29:59.625664', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('3dff4cc5-e1c2-4969-914e-63e78f329f37', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:33:30.953481', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('88ee0d2d-a3fd-4d2e-ad3f-e5cb15debb2f', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:36:06.337278', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('ff4289c3-79a3-488f-937a-b9495d9a8d6e', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:36:21.996658', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('46ff8c34-0823-4019-944c-8c7df2f22de9', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:36:53.209014', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('35867541-1a2c-4d1b-9268-72cff06f3517', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:38:23.769847', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('0454b733-b902-41e2-a193-b9b152e5dda7', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:39:17.369435', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('ec04d8b6-80ef-4a59-914f-d9d22a78b9fc', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:40:48.907662', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');
INSERT INTO public.login VALUES ('65609acf-39c7-45a6-a832-aed63158397d', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2025-10-23 11:41:15.664243', '127.0.0.1', 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0');


--
-- TOC entry 3800 (class 0 OID 31089)
-- Dependencies: 247
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.role VALUES ('88e07160-2df2-4d18-ab38-9b4668267956', 'withdrawal');
INSERT INTO public.role VALUES ('1f65261b-a275-4b10-a71d-a556f3525428', 'deposit');
INSERT INTO public.role VALUES ('05865b54-4591-4ccb-b1b8-bacf4c8771a2', 'account-open');
INSERT INTO public.role VALUES ('87b01ec1-46ba-42bb-975b-4d25c16582b6', 'account-close');
INSERT INTO public.role VALUES ('5d8461b9-9f7d-4c8e-8306-91760ef30a9b', 'fd-create');
INSERT INTO public.role VALUES ('6b116c56-efe7-45eb-883b-b3e7d5f68145', 'fd-close');
INSERT INTO public.role VALUES ('34dbe9a4-95a3-4abb-9442-5a78ea632af9', 'user-create');
INSERT INTO public.role VALUES ('6b238ef4-bce5-4c9a-85d6-795178e85ea3', 'admin');
INSERT INTO public.role VALUES ('fe6b7dfa-8e54-4539-8bb6-3546e26ccd30', 'agent');
INSERT INTO public.role VALUES ('ce1a460c-e571-48b7-8b21-1d4aac270849', 'manager');
INSERT INTO public.role VALUES ('9c3adbb6-6ae6-4800-a65b-f78e78649078', 'fd-view');
INSERT INTO public.role VALUES ('934d3f0b-e687-4de3-8e70-bdc9cbc775bf', 'account-view');
INSERT INTO public.role VALUES ('17e15824-573e-4bdd-8079-1daabc0a563b', 'customer-view');
INSERT INTO public.role VALUES ('3765a6c7-6ac2-4faf-9f71-3088378b3fdd', 'customer-update');
INSERT INTO public.role VALUES ('49cc2c12-f54e-4088-a129-678e6aec7312', 'report-view');
INSERT INTO public.role VALUES ('b7ce085d-d88e-4291-a0ab-efcc14a1ae3e', 'transfer');


--
-- TOC entry 3801 (class 0 OID 31093)
-- Dependencies: 248
-- Data for Name: savings_plan; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.savings_plan VALUES ('7d8f328d-650d-4e19-b2ef-4c7292f6264a', 'Joint', 7.00, '2025-09-18 10:27:13.250715', '2025-10-14 21:05:51.619325', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 5000);
INSERT INTO public.savings_plan VALUES ('75cb0dfb-be48-4b4c-ab13-9e01772f0332', 'Children', 12.00, '2025-09-18 13:35:04.860764', '2025-10-14 21:05:51.620268', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 0);
INSERT INTO public.savings_plan VALUES ('fd8afec3-3da2-48ab-a63d-abbff3a3e773', 'Senior', 13.00, '2025-10-14 21:05:51.612605', '2025-10-14 21:06:17.110416', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 1000);
INSERT INTO public.savings_plan VALUES ('a620a5c0-9456-4bc6-a37c-1c02d8f0da9c', 'Teen', 11.00, '2025-10-14 21:05:51.615497', '2025-10-14 21:06:17.112064', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 500);
INSERT INTO public.savings_plan VALUES ('3578bd55-8c57-4757-aa7b-0f37b859edd6', 'Adult', 10.00, '2025-09-18 10:25:36.776016', '2025-10-20 17:19:47.349057', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 1000);
INSERT INTO public.savings_plan VALUES ('e509eb83-b653-4f30-96d2-ee598b43bd0c', 'Vanitha', 13.00, '2025-09-10 15:03:07.559011', '2025-10-23 11:38:39.671117', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 500);


--
-- TOC entry 3802 (class 0 OID 31099)
-- Dependencies: 249
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.transactions VALUES ('63b9dd87-d4db-4a78-aa84-243564a6ce89', 9205.48, '1dfe7946-7b05-4de1-8254-1528660baf18', 'Deposit', 'FD Interest - FD Account No: 56537165', '2025-10-16 12:01:19.431619', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 14018592314612);
INSERT INTO public.transactions VALUES ('f8ea0e02-d0b6-484b-8678-043d88e1fdf6', 1380.82, '3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 'Deposit', 'FD Interest - FD Account No: 15795036', '2025-10-16 12:01:19.431619', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 606730190391194);
INSERT INTO public.transactions VALUES ('d16a4006-cfbd-4d25-ac3c-c4908c4b3d2b', 7397.26, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Deposit', 'FD Interest - FD Account No: 21395338', '2025-10-16 12:01:19.431619', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 888570330890963);
INSERT INTO public.transactions VALUES ('400e75c2-0ed1-4693-bd9f-2a8b151bcdfb', 2465.74, '9f195429-65fc-48c0-8a22-3216088f897e', 'Deposit', 'FD Interest - FD Account No: 94769260', '2025-10-16 12:01:19.431619', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 948128527194124);
INSERT INTO public.transactions VALUES ('ef5d0db2-30b5-4c7e-83f5-34cc5bf3bb15', 1068.49, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Deposit', 'FD Interest - FD Account No: 10832252', '2025-10-16 12:01:19.431619', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 816759911847507);
INSERT INTO public.transactions VALUES ('451ecfc1-427f-4f54-b292-ea3b8b1e843d', 1150.68, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Deposit', 'FD Interest - FD Account No: 71876545', '2025-10-03 12:01:10.850765', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 453974105399930);
INSERT INTO public.transactions VALUES ('d2a8af0b-f046-418b-ab2f-a539c06b783e', 2301.37, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'FD Interest - FD Account No: 63351599', '2025-10-03 12:01:10.850765', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 54778344047779);
INSERT INTO public.transactions VALUES ('f254245d-aeda-44eb-978d-7dde7573784b', 4931.49, 'd38f3e7a-9414-40e4-b62f-47019c16be6b', 'Deposit', 'FD Interest - FD Account No: 80741694', '2025-09-28 12:01:06.107982', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 23750929833223);
INSERT INTO public.transactions VALUES ('68fbbccd-d449-4060-b76e-88a2cd47db97', 2646.56, '99280df3-2bad-4c61-b069-bf6144235552', 'Deposit', 'FD Interest - FD Account No: 56004431', '2025-09-30 12:01:03.698862', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 176795004208790);
INSERT INTO public.transactions VALUES ('5671a1fd-3b67-4412-b3c7-f22bf443f003', 4602.74, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Deposit', 'FD Interest - FD Account No: 10915296', '2025-09-26 14:45:06.944417', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 582593856122779);
INSERT INTO public.transactions VALUES ('e909a5c1-575b-4dca-9da9-1553a67478b2', 1150.68, 'a949c77a-bb3b-484f-9b3e-8d68a36deb87', 'Deposit', 'FD Interest - FD Account No: 13412211', '2025-09-26 14:45:06.944417', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 841867798214659);
INSERT INTO public.transactions VALUES ('ae302cb2-8eb5-4970-9951-68605919952b', 3698.63, 'b79aefad-de0e-4387-84cb-7a1234ce4ce7', 'Deposit', 'FD Interest - FD Account No: 93664811', '2025-09-26 14:45:06.944417', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 56013056213888);
INSERT INTO public.transactions VALUES ('c29db8ad-1a13-435f-96e1-9f0812a0268c', 2136.99, '17c9a664-3b42-456e-95e4-4bd73353f0e0', 'Deposit', 'FD Interest - FD Account No: 43639715', '2025-09-26 14:45:06.944417', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 457949508762786);
INSERT INTO public.transactions VALUES ('14579a24-138d-4a50-a987-06d42b2fefee', 10000.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Deposit', 'Sallary', '2025-08-04 10:44:47.493376', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 233766225784486);
INSERT INTO public.transactions VALUES ('522db6ce-a91a-41f2-85bf-d026fc9f782f', 98000.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Deposit', 'Check ', '2025-08-04 10:45:18.606736', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 100093345681520);
INSERT INTO public.transactions VALUES ('c70baf92-3a9e-4c22-8457-c8fdc99d0357', 43000.00, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Deposit', 'Personal', '2025-08-04 10:46:41.642958', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 846955169766839);
INSERT INTO public.transactions VALUES ('d5c355db-d9b5-488d-967e-cb67f142a1d4', 33000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Deposit', 'Personal', '2025-08-04 10:47:59.87012', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 308166398258909);
INSERT INTO public.transactions VALUES ('84ab6ce6-ec4a-4f19-b66c-f5b65d66d5c7', 32000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Deposit', '6700', '2025-08-04 10:48:30.336696', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 959459688278479);
INSERT INTO public.transactions VALUES ('7dde4a7a-fc06-41a8-ad02-fe4730445fec', 200000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'Created fixed deposit', '2025-08-04 10:49:54.170884', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 891258611149345);
INSERT INTO public.transactions VALUES ('e0db2998-ec93-4edc-b729-ad6601811ccc', 2300.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Withdrawal', 'Bill payment', '2025-08-04 10:50:43.613913', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 630818209392564);
INSERT INTO public.transactions VALUES ('676f8996-5117-4466-b205-9f32f54d04a1', 2400.00, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Withdrawal', 'Bill payment', '2025-08-04 10:51:24.2614', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 159043790305421);
INSERT INTO public.transactions VALUES ('ed117189-360d-402b-bcf5-11f88a37cdd6', 10000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Withdrawal', 'Personal', '2025-08-04 10:51:54.899721', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 427883733807627);
INSERT INTO public.transactions VALUES ('be7cd947-e30c-418a-8307-d54318a7f3de', 2344.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Withdrawal', 'Water Bill', '2025-08-04 10:52:22.570051', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 187418094060708);
INSERT INTO public.transactions VALUES ('b7fd3e67-1c49-4248-b185-48d10c31d6d4', 99998.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Deposit', 'Created fixed deposit', '2025-08-04 10:53:02.758006', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 878733600697052);
INSERT INTO public.transactions VALUES ('2af50c8d-4c47-461a-a4ca-0e87783c7ee9', 100000.00, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Deposit', 'Created fixed deposit', '2025-08-04 10:53:38.203207', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 474571970664831);
INSERT INTO public.transactions VALUES ('b23c1fda-c07d-409c-9a5e-1715911059da', 2000000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Deposit', 'Created fixed deposit', '2025-08-04 10:55:30.564301', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 608567391196330);
INSERT INTO public.transactions VALUES ('9bf8d548-cde2-4796-ac5e-0df75f63db89', 2000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'BankTransfer-Out', 'Bill paymemnt', '2025-08-04 10:57:50.874534', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 925251627819895);
INSERT INTO public.transactions VALUES ('699918a3-4bbe-4534-9f45-e250078f7dea', 2000.00, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'BankTransfer-In', 'Bill paymemnt', '2025-08-04 10:57:50.874534', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 234217695287104);
INSERT INTO public.transactions VALUES ('0b3588c3-b3aa-4a85-937f-b1961e8dd322', 3000.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'BankTransfer-Out', 'Done', '2025-08-04 10:58:21.665601', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 683231767129892);
INSERT INTO public.transactions VALUES ('e733c8a8-d7e0-4e8c-ac65-faa608622490', 3000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'BankTransfer-In', 'Done', '2025-08-04 10:58:21.665601', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 192350581972277);
INSERT INTO public.transactions VALUES ('469f5582-f6e4-4bf4-ac62-1ebe5ab9295f', 8000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Withdrawal', 'Personal', '2025-08-04 10:59:20.511609', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 980985409463095);
INSERT INTO public.transactions VALUES ('f82d792f-2af2-4c83-ad59-5cb79144cb92', 500.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'Saving
', '2025-08-04 11:00:54.137342', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 244498200230885);
INSERT INTO public.transactions VALUES ('d356b9fc-0534-4ecf-9908-1fa05cc6aa5a', 3200.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Deposit', 'Personal
', '2025-08-05 12:30:59.246401', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 192951179938602);
INSERT INTO public.transactions VALUES ('7f1f7069-988e-4d7a-9903-4c7fd3120ace', 5200.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Withdrawal', 'Payment', '2025-08-05 12:31:28.863041', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 600174574521869);
INSERT INTO public.transactions VALUES ('3cad6719-1930-49d8-a85e-032b15f87519', 25000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Deposit', 'Personal', '2025-08-05 12:31:34.123095', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 958580063370022);
INSERT INTO public.transactions VALUES ('9fc86c17-ba77-45da-b196-91640da576ca', 2000.00, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Deposit', 'personal', '2025-08-05 12:31:49.902137', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 445893446635889);
INSERT INTO public.transactions VALUES ('c7ce210c-4aa8-4fcc-945c-c6b144b20c60', 2400.00, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Withdrawal', 'Bill', '2025-08-05 12:32:08.168988', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 850610103039573);
INSERT INTO public.transactions VALUES ('299fd719-1739-414b-b137-1790c2646f06', 5199.98, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-Out', 'Payment', '2025-08-05 12:32:23.431327', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 165346769189871);
INSERT INTO public.transactions VALUES ('816a5981-5cdb-45b7-af4f-ae0d6b70586a', 5199.98, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'BankTransfer-In', 'Payment', '2025-08-05 12:32:23.431327', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 33909934646286);
INSERT INTO public.transactions VALUES ('40f24b29-b2ee-43f0-ad1f-53835f34e004', 2000.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'Personal', '2025-08-07 13:30:41.048447', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 808768432148864);
INSERT INTO public.transactions VALUES ('f71a3f2f-1f17-4e18-a0c9-c5f0f2eb021d', 23000.00, '9f195429-65fc-48c0-8a22-3216088f897e', 'Deposit', 'Personal', '2025-08-07 13:32:23.543813', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 568031854237967);
INSERT INTO public.transactions VALUES ('95ef3b17-93af-4f7e-ae41-1b1ac5b045a1', 999.98, '9f195429-65fc-48c0-8a22-3216088f897e', 'Withdrawal', 'Personal', '2025-08-07 13:35:29.031872', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 330000908805931);
INSERT INTO public.transactions VALUES ('736d1cdb-d187-449b-9910-d620775cfdf5', 3000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'BankTransfer-Out', 'Take this', '2025-08-07 13:36:21.069255', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 541907843301375);
INSERT INTO public.transactions VALUES ('442bceeb-a33b-49f6-b261-c3d4dbd7db4e', 3000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'BankTransfer-In', 'Take this', '2025-08-07 13:36:21.069255', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 12671232075090);
INSERT INTO public.transactions VALUES ('5c772b7c-2669-4e11-a63d-45ea1d19044a', 3000.00, '9f195429-65fc-48c0-8a22-3216088f897e', 'BankTransfer-Out', 'Take this', '2025-08-17 08:30:42.594954', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 763540025470967);
INSERT INTO public.transactions VALUES ('30b16876-d32d-475a-85d7-92f5412169ea', 3000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'BankTransfer-In', 'Take this', '2025-08-17 08:30:42.594954', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 334958114797412);
INSERT INTO public.transactions VALUES ('447e6b15-1bf0-43cd-b3cf-972be8e23211', 199999.00, '9f195429-65fc-48c0-8a22-3216088f897e', 'Deposit', 'Created fixed deposit', '2025-08-17 08:31:41.339773', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 595593109431959);
INSERT INTO public.transactions VALUES ('f023c5fa-1e70-4c36-a643-7bc9637c66ba', 800000.00, '1dfe7946-7b05-4de1-8254-1528660baf18', 'Deposit', 'Created fixed deposit', '2025-08-17 08:31:53.82927', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 924511524052996);
INSERT INTO public.transactions VALUES ('f77c19e0-7280-42e1-ba04-1c0bb3cfa287', 5000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'payment', '2025-08-17 08:34:59.356683', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 448140930234823);
INSERT INTO public.transactions VALUES ('b974c18a-6c0b-4bdd-aaf1-ac00580c3a31', 5000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Withdrawal', 'tax ', '2025-08-17 08:35:50.884989', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 275197950574655);
INSERT INTO public.transactions VALUES ('7fc38df2-000e-4ce0-ba81-86129b79242b', 600000.00, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Deposit', 'Created fixed deposit', '2025-08-17 08:37:04.355603', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 793936987527385);
INSERT INTO public.transactions VALUES ('92cfea1a-144e-41eb-b920-12f5dde52f5c', 120000.00, '3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 'Deposit', 'Created fixed deposit', '2025-08-17 08:41:43.769728', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 921785847593361);
INSERT INTO public.transactions VALUES ('7a1e8735-261f-47e5-9af7-2386a67cc527', 100000.00, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Deposit', 'Created fixed deposit', '2025-08-17 08:41:56.329298', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 758436337959993);
INSERT INTO public.transactions VALUES ('41c9ee83-761f-462d-8055-92fe5a76bdf8', 2500.00, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'BankTransfer-Out', 'Internet fee', '2025-08-17 08:43:20.76822', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 695629444431312);
INSERT INTO public.transactions VALUES ('f0de181d-a334-4138-8b61-3ecd55db38cb', 2500.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-In', 'Internet fee', '2025-08-17 08:43:20.76822', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 553985014577781);
INSERT INTO public.transactions VALUES ('b670bea3-fd66-49a1-b9bd-75c056d4b630', 1000.00, '4dcf9c4f-2bec-49f9-a336-5e45cce1601b', 'Withdrawal', 'Closed the account.', '2025-08-17 08:46:06.297365', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 803546652739197);
INSERT INTO public.transactions VALUES ('f0fdc187-dd54-4eae-93a2-072354e61053', 2000000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Withdrawal', 'Fixed deposit cloesd', '2025-08-17 08:46:35.359263', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 617961073555801);
INSERT INTO public.transactions VALUES ('04925b39-acf3-402a-b4d3-90b84a91e10d', 200000.00, '17c9a664-3b42-456e-95e4-4bd73353f0e0', 'Deposit', 'Created fixed deposit', '2025-08-27 08:30:21.300452', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 677645591134287);
INSERT INTO public.transactions VALUES ('261e5db5-8b4b-4317-9ef1-4096c6133e96', 400000.00, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Deposit', 'Created fixed deposit', '2025-08-27 08:30:21.836043', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 75613340186077);
INSERT INTO public.transactions VALUES ('673fcaf4-cc52-423e-ba56-8a9105aec53f', 300000.00, 'b79aefad-de0e-4387-84cb-7a1234ce4ce7', 'Deposit', 'Created fixed deposit', '2025-08-27 08:33:38.71221', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 801002457470757);
INSERT INTO public.transactions VALUES ('3517fe0d-f03d-4c36-af2d-a63f37ffc453', 99998.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Withdrawal', 'Fixed deposit cloesd', '2025-08-27 08:34:13.678095', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 240676670364052);
INSERT INTO public.transactions VALUES ('784845e8-5453-4e56-b54a-d668fc190633', 100000.00, 'a949c77a-bb3b-484f-9b3e-8d68a36deb87', 'Deposit', 'Created fixed deposit', '2025-08-27 08:37:53.929716', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 631741186332230);
INSERT INTO public.transactions VALUES ('d1928112-d1ee-4bac-a4da-b3036d3b4910', 399999.00, 'd38f3e7a-9414-40e4-b62f-47019c16be6b', 'Deposit', 'Created fixed deposit', '2025-08-29 08:30:23.777358', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 282035983504143);
INSERT INTO public.transactions VALUES ('cee0fcfd-2bf9-4011-8022-adc4ca9f2e36', 229999.00, '99280df3-2bad-4c61-b069-bf6144235552', 'Deposit', 'Created fixed deposit', '2025-08-31 08:30:04.259167', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 48086120460434);
INSERT INTO public.transactions VALUES ('a5ded5dc-b117-44ab-a0d8-0ab0ae89e573', 8.56, '0415f29e-fb5b-4756-baa6-bce59cab2be5', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 786119345674491);
INSERT INTO public.transactions VALUES ('3b3ec2d7-9834-44bb-bf34-67d970a80b85', 192.76, '17c9a664-3b42-456e-95e4-4bd73353f0e0', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 3469287399098);
INSERT INTO public.transactions VALUES ('c8f79a9b-8bb4-4772-b9a4-ea801d2587c1', 8.63, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 468415263696005);
INSERT INTO public.transactions VALUES ('a8ba776a-446d-46b8-b2a9-ae974962acb5', 164.38, '1dfe7946-7b05-4de1-8254-1528660baf18', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 731391316673196);
INSERT INTO public.transactions VALUES ('90eaf77d-4969-474e-9465-e10368e9e210', 702.58, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 909083557338330);
INSERT INTO public.transactions VALUES ('5d1b0f30-a28d-401c-8bb5-8c3d710a5bff', 0.14, '31d95fe1-7d2f-4d9e-81c1-b608131b7335', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 571208647605809);
INSERT INTO public.transactions VALUES ('25a6d126-f3ee-452b-bd56-51919c29893c', 304.24, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 109176933892360);
INSERT INTO public.transactions VALUES ('6deaa37b-0d72-414b-88b2-ebe6e87bb3c2', 189.04, '3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 749982791848859);
INSERT INTO public.transactions VALUES ('a658ffff-7e26-46ac-9fad-350d3402757e', 203.84, '3b4fe46d-d998-4231-bf48-9552830244fe', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 871693885463749);
INSERT INTO public.transactions VALUES ('ef83258c-8c97-49ab-84d6-d2e0e405240e', 424.93, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 203218698705735);
INSERT INTO public.transactions VALUES ('196579a7-e94f-413a-b18d-637e8feacd47', 3566.19, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 121946978238852);
INSERT INTO public.transactions VALUES ('125cae41-20f6-4c1c-af7f-af74ae24db26', 271.78, '6793b998-92c2-45bb-a4d4-1b84fefbc652', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 240539138885115);
INSERT INTO public.transactions VALUES ('4259e8c8-bcad-45b4-b609-3486264b9f57', 57.82, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 166849691989130);
INSERT INTO public.transactions VALUES ('9b248fd4-b596-4cee-b378-c792a88f1101', 198.99, '99280df3-2bad-4c61-b069-bf6144235552', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 638579945850740);
INSERT INTO public.transactions VALUES ('85414586-9239-4a94-b565-10877f793ed4', 342.58, '9f195429-65fc-48c0-8a22-3216088f897e', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 933489700043858);
INSERT INTO public.transactions VALUES ('8f90f253-2ded-43e0-94d7-fbf5f6c604f4', 101.10, 'a949c77a-bb3b-484f-9b3e-8d68a36deb87', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 701807215338034);
INSERT INTO public.transactions VALUES ('91a1fb35-29e5-4e80-906e-896bafdc4daf', 1163.75, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 360777693330867);
INSERT INTO public.transactions VALUES ('7a3ffda4-551d-476a-95eb-5ced39d8ebda', 17381.29, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 403008755686430);
INSERT INTO public.transactions VALUES ('2a56c372-b6a3-4ed5-940b-b258b60be02d', 355.07, 'b79aefad-de0e-4387-84cb-7a1234ce4ce7', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 629507587379318);
INSERT INTO public.transactions VALUES ('d19fa719-23d8-4c8a-945d-5cc6e52a53db', 88.63, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 315611121043923);
INSERT INTO public.transactions VALUES ('38bad065-a77f-458d-a7df-8c8a4cf1a528', 945.61, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 260679383631026);
INSERT INTO public.transactions VALUES ('8c09a256-bc07-4671-98ed-5f0ba86dae3b', 2032.67, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 854507687289358);
INSERT INTO public.transactions VALUES ('5ef10d10-0fc5-4805-95aa-1b0142866a6f', 377.26, 'd38f3e7a-9414-40e4-b62f-47019c16be6b', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 857162306285792);
INSERT INTO public.transactions VALUES ('4c3f1f9e-5dac-4bac-b98e-a2bcee70986c', 594.52, 'dffecccc-565a-4b66-804c-1befa178b8f7', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 755092205846023);
INSERT INTO public.transactions VALUES ('e7f96959-bcc1-4030-842e-fe1ba32a43f2', 17.64, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 399775602375655);
INSERT INTO public.transactions VALUES ('70c81655-82e1-4c84-8716-3d6085989fda', 2877.31, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 587798131553037);
INSERT INTO public.transactions VALUES ('ef28cc09-cc96-4324-8cec-80116a85e49c', 101.92, 'e260aeef-4836-4a35-bb19-3d109adba141', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 909730322734713);
INSERT INTO public.transactions VALUES ('2f98b1f5-9a40-4f63-89d7-22b23f730193', 673.67, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 714703566868243);
INSERT INTO public.transactions VALUES ('ef7a49ef-9eff-4d32-8d0d-1c96c7ef9c11', 8.63, 'fb762c41-c883-4bba-9bcf-f59dfc07f042', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 802897004290918);
INSERT INTO public.transactions VALUES ('32e33443-f80c-418a-ac2e-3a555d9157d2', 12.24, 'fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 849171630950879);
INSERT INTO public.transactions VALUES ('d6dac7a1-6a4b-425d-92a9-3b794a7f79ed', 98.87, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 941870631450769);
INSERT INTO public.transactions VALUES ('2b306f53-64f4-4d4f-b011-be4769cdf266', 7.25, 'fde6ebe4-72be-4574-a470-999a365b1529', 'Interest', 'Monthly interest', '2025-09-01 08:30:44.216391', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 349276778269250);
INSERT INTO public.transactions VALUES ('c4b79ee6-e9bf-4ae7-8dbf-c745dd3b7bc8', 2100.00, '30159eb0-328d-4cf2-84a3-d7f51040ed22', 'Withdrawal', 'For food', '2025-09-01 08:32:54.183191', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 501296354163839);
INSERT INTO public.transactions VALUES ('b2371d72-2025-4798-9410-dbca0c759309', 200.00, '30159eb0-328d-4cf2-84a3-d7f51040ed22', 'BankTransfer-Out', 'Lunch money', '2025-09-01 08:33:32.560933', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 221402269692969);
INSERT INTO public.transactions VALUES ('b4237768-bcf5-4c6b-a44c-5f48a99f2ae5', 200.00, '1dfe7946-7b05-4de1-8254-1528660baf18', 'BankTransfer-In', 'Lunch money', '2025-09-01 08:33:32.560933', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 447445185711737);
INSERT INTO public.transactions VALUES ('a738a258-feed-4bc9-aa99-757390f22274', 299999.00, '697a0943-3418-427b-9786-45b5c5066b71', 'Deposit', 'Created fixed deposit', '2025-09-01 08:36:29.090507', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 668761158951008);
INSERT INTO public.transactions VALUES ('4306549a-4219-43c2-bc50-e2c41ffd2d00', 5000.00, '1dfe7946-7b05-4de1-8254-1528660baf18', 'Withdrawal', 'personal', '2025-09-01 08:38:57.134029', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 579519848696426);
INSERT INTO public.transactions VALUES ('ec805c75-0560-49b0-af81-a7417a53d71f', 4000.00, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Withdrawal', 'personal', '2025-09-05 10:30:41.081559', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 930562001092932);
INSERT INTO public.transactions VALUES ('cc4c3c97-9dbd-4098-939a-fe76e786379a', 500.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Withdrawal', 'Pocket money', '2025-09-05 10:31:18.661311', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 850405277746172);
INSERT INTO public.transactions VALUES ('1d7c9420-b73e-41ee-82fd-9d236d0a2d5f', 5000.00, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'Deposit', 'saving', '2025-09-05 10:31:43.425096', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 563365075014141);
INSERT INTO public.transactions VALUES ('cf893ba0-5920-41f3-9731-7872dd227f54', 1000.00, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'BankTransfer-Out', 'Monthly allowance', '2025-09-05 10:32:15.272903', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 541354781451673);
INSERT INTO public.transactions VALUES ('93e2b22b-4354-436b-8dc1-7ee79ebef935', 1000.00, '0415f29e-fb5b-4756-baa6-bce59cab2be5', 'BankTransfer-In', 'Monthly allowance', '2025-09-05 10:32:15.272903', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 309533188198091);
INSERT INTO public.transactions VALUES ('500ac7bc-bb10-46d8-a351-8c50cd7e54fc', 100000.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Deposit', 'Created fixed deposit', '2025-09-05 10:34:04.982865', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 619900040025369);
INSERT INTO public.transactions VALUES ('33786014-df26-40c8-a8eb-4c7a4a164122', 50000.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Deposit', 'Created fixed deposit', '2025-09-05 10:36:28.875612', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 474514638277256);
INSERT INTO public.transactions VALUES ('c0b96c11-43bd-4a15-80f4-49731a447137', 50000.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Withdrawal', 'Fixed deposit cloesd', '2025-09-05 10:37:16.65028', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 64427099649737);
INSERT INTO public.transactions VALUES ('203c199e-6d60-4832-8152-5895274b3c34', 10000.00, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'BankTransfer-Out', 'My account', '2025-09-10 12:32:24.698127', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 583113156206609);
INSERT INTO public.transactions VALUES ('da2a89ea-6207-4ce2-a8ff-8c4eb1ddbc93', 10000.00, 'ded1f289-7f01-4135-b638-dd735d691229', 'BankTransfer-In', 'My account', '2025-09-10 12:32:24.698127', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 435020000188239);
INSERT INTO public.transactions VALUES ('0aa25dbb-2ce1-4e51-921a-9a4b69d328a0', 7000.00, '30159eb0-328d-4cf2-84a3-d7f51040ed22', 'Deposit', 'Saving', '2025-09-10 12:32:52.788853', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 686476245232802);
INSERT INTO public.transactions VALUES ('1764553d-a998-44cf-89b7-f6b719046cc3', 49999.00, '30159eb0-328d-4cf2-84a3-d7f51040ed22', 'Deposit', 'Created fixed deposit', '2025-09-10 12:33:35.338774', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 894870267207771);
INSERT INTO public.transactions VALUES ('1eb9d5be-6fdf-46ed-b54c-413b14572e19', 200.00, '31d95fe1-7d2f-4d9e-81c1-b608131b7335', 'Deposit', 'Saving', '2025-09-03 00:00:44.035869', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 396131224199532);
INSERT INTO public.transactions VALUES ('ebcd99e9-eed0-4af5-aac1-bd836b3fd828', 2400.00, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Withdrawal', 'Private reason', '2025-09-04 00:00:42.60215', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 461293163472035);
INSERT INTO public.transactions VALUES ('7eb2cae4-8771-48b3-a8b2-ceba6e1a9286', 10000.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'BankTransfer-Out', 'Salary payment', '2025-09-04 00:01:15.496851', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 861419901987331);
INSERT INTO public.transactions VALUES ('c641ad2b-a957-4e7d-8f69-13402da12fe0', 10000.00, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'BankTransfer-In', 'Salary payment', '2025-09-04 00:01:15.496851', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 737018446034534);
INSERT INTO public.transactions VALUES ('a5d2c12e-f638-40ff-ae16-5615ac9afc2f', 1150.68, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Deposit', 'FD Interest - FD Account No: 71876545', '2025-09-03 00:00:09.103004', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 245571352257359);
INSERT INTO public.transactions VALUES ('cc4e6c78-5653-4c5e-aa71-bdc044a55f5b', 2301.37, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'FD Interest - FD Account No: 63351599', '2025-09-03 00:00:09.103004', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 998788217324572);
INSERT INTO public.transactions VALUES ('6cf4acd2-07b9-4559-bb75-43720b68cdf7', 32000.00, '7fe7a775-2411-423a-84fa-e3ed126ec6c3', 'Deposit', 'Personal', '2025-09-10 15:02:36.709334', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 328772665636933);
INSERT INTO public.transactions VALUES ('afddd3f7-70ac-41e1-bba8-dd2a1bca040d', 54000.00, '7fe7a775-2411-423a-84fa-e3ed126ec6c3', 'Withdrawal', 'Bill', '2025-09-10 15:02:53.681667', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 562255120348248);
INSERT INTO public.transactions VALUES ('82e44516-58fc-4c29-90ff-f226c9348c12', 8700.00, '1853d4ea-a229-4757-9a4c-f6f858351196', 'Deposit', 'Personal', '2025-09-10 15:04:21.801777', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 701757036242397);
INSERT INTO public.transactions VALUES ('648c3a6f-5b83-4fb5-a11b-d56f05a3d754', 430.00, '1853d4ea-a229-4757-9a4c-f6f858351196', 'Withdrawal', 'Bill', '2025-09-10 15:05:19.438702', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 345198756307786);
INSERT INTO public.transactions VALUES ('1afcd787-ca28-4b3e-aac3-3b2a87d9c527', 399999.00, '1853d4ea-a229-4757-9a4c-f6f858351196', 'Deposit', 'Created fixed deposit', '2025-09-10 15:05:29.263694', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 502013425194808);
INSERT INTO public.transactions VALUES ('09bbd243-f397-435f-8eb0-a13cb31cfcbf', 5000000.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Deposit', 'Created fixed deposit', '2025-09-10 15:06:25.913042', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 817015098533773);
INSERT INTO public.transactions VALUES ('acb9267b-e8b6-4e64-89f0-8b6289c3dc85', 500.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-Out', 'Saving', '2025-09-10 15:07:03.63283', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 937943578085138);
INSERT INTO public.transactions VALUES ('30099ab9-190d-48cf-b800-361740283b57', 500.00, '2955457b-8207-4228-a3da-c9d5940c2095', 'BankTransfer-In', 'Saving', '2025-09-10 15:07:03.63283', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 78808023563933);
INSERT INTO public.transactions VALUES ('e94aef48-1ce4-4cf9-aabc-41946549c6c1', 7000.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', 'salary', '2025-09-10 15:07:35.287624', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 429533734334319);
INSERT INTO public.transactions VALUES ('c71aafad-481c-432b-9c15-6fc1ae302ba2', 11999.99, '4ae3fefd-a3d4-4133-b516-bddebdf3d49f', 'BankTransfer-Out', 'For rent', '2025-09-10 15:07:43.480479', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 837076895636833);
INSERT INTO public.transactions VALUES ('2028e0f1-c7c8-4b9d-bca6-3ec37adf3d28', 11999.99, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'BankTransfer-In', 'For rent', '2025-09-10 15:07:43.480479', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 906200046294482);
INSERT INTO public.transactions VALUES ('588b8ae2-8aa8-49cf-850b-9d65f84ee1d9', 1000.00, '2955457b-8207-4228-a3da-c9d5940c2095', 'Deposit', 'Gift', '2025-09-10 15:08:06.527219', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 307878725342264);
INSERT INTO public.transactions VALUES ('a4b06409-ee74-4f16-9f34-8892922dc944', 7000.00, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Withdrawal', 'personal', '2025-09-15 11:02:13.758872', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 307414968499016);
INSERT INTO public.transactions VALUES ('08a2fa70-3e44-4090-9b1a-2d3d308d14b0', 250.00, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Withdrawal', 'Personal', '2025-09-15 11:02:33.810443', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 241531339701049);
INSERT INTO public.transactions VALUES ('bfb33379-edd1-4d12-9cfb-544287bd3c47', 584.00, 'fb762c41-c883-4bba-9bcf-f59dfc07f042', 'Deposit', 'Water bill', '2025-09-15 11:02:59.786989', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 254427215619831);
INSERT INTO public.transactions VALUES ('5c566111-a61e-4193-9454-acc293b3bb5e', 100000.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Deposit', 'Pension', '2025-09-15 11:03:42.268459', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 226099169754925);
INSERT INTO public.transactions VALUES ('23f5b2a0-b423-4e79-978e-62a8af4b5a70', 10000.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Withdrawal', 'For TV', '2025-09-15 11:04:06.179024', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 732722992586431);
INSERT INTO public.transactions VALUES ('ab340ac0-c756-4e5b-a621-cc8656519fd0', 4000.00, 'ded1f289-7f01-4135-b638-dd735d691229', 'BankTransfer-Out', 'Saving', '2025-09-15 11:04:27.782048', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 705214579947519);
INSERT INTO public.transactions VALUES ('f362666a-3fb3-4450-80f3-090c3487b7bd', 4000.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-In', 'Saving', '2025-09-15 11:04:27.782048', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 547849218285121);
INSERT INTO public.transactions VALUES ('c5da2f86-62a3-4568-9a8a-4d830f1aa6aa', 1000000.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Deposit', 'Created fixed deposit', '2025-09-15 11:04:35.869121', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 585875275223093);
INSERT INTO public.transactions VALUES ('6413d073-38ab-4330-ad32-cf07efa155e3', 7397.26, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Deposit', 'FD Interest - FD Account No: 21395338', '2025-09-16 11:00:18.296315', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 947319253706467);
INSERT INTO public.transactions VALUES ('b48c554d-5672-4013-8900-2f3598f83c8c', 9205.48, '1dfe7946-7b05-4de1-8254-1528660baf18', 'Deposit', 'FD Interest - FD Account No: 56537165', '2025-09-16 11:00:18.296315', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 228351724268026);
INSERT INTO public.transactions VALUES ('513b66b5-3fdb-4018-905c-988716182f68', 1380.82, '3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 'Deposit', 'FD Interest - FD Account No: 15795036', '2025-09-16 11:00:18.296315', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 769408096433223);
INSERT INTO public.transactions VALUES ('36a3bfeb-2d6d-4063-b4de-919e49df6342', 2465.74, '9f195429-65fc-48c0-8a22-3216088f897e', 'Deposit', 'FD Interest - FD Account No: 94769260', '2025-09-16 11:00:18.296315', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 244319960842086);
INSERT INTO public.transactions VALUES ('d89ab62d-5f30-49e8-98c7-d24e56f274c3', 1068.49, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Deposit', 'FD Interest - FD Account No: 10832252', '2025-09-16 11:00:18.296315', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 164787646638323);
INSERT INTO public.transactions VALUES ('7ab04e66-a77b-4983-98d8-12ddd7608331', 3400.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Withdrawal', 'gatta', '2025-09-18 11:00:57.88997', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 452376709342030);
INSERT INTO public.transactions VALUES ('78b1fd6f-480b-41e9-bc43-f7b349e0d171', 5200.00, 'ded1f289-7f01-4135-b638-dd735d691229', 'Withdrawal', 'Personal', '2025-09-18 11:01:01.276122', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 576192793762546);
INSERT INTO public.transactions VALUES ('aff6b515-5087-4b0a-bb10-64b698663a21', 5200.00, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Withdrawal', 'Bill', '2025-09-18 11:01:14.55768', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 273514566228009);
INSERT INTO public.transactions VALUES ('a17a2ebd-c02e-45fc-8905-d4dc2cb4f390', 129.98, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'BankTransfer-Out', 'For rent', '2025-09-18 11:01:21.130191', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 185779490134378);
INSERT INTO public.transactions VALUES ('ee189c2a-229f-4734-bfb3-869f5adff721', 129.98, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'BankTransfer-In', 'For rent', '2025-09-18 11:01:21.130191', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 237787943826026);
INSERT INTO public.transactions VALUES ('ce31cf93-8306-45c2-8e63-4d82dcd1b4c4', 1000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'Saving', '2025-09-20 11:00:02.077364', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 610476440447935);
INSERT INTO public.transactions VALUES ('8c503150-430d-4ebf-bdef-7ea74cd3d236', 3000000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Deposit', 'Sallary', '2025-09-20 11:00:18.789421', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 743534993868353);
INSERT INTO public.transactions VALUES ('4deae24f-baef-4ec1-9a06-334219d3e042', 250.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'light bill', '2025-09-20 11:00:25.739069', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 105477415229773);
INSERT INTO public.transactions VALUES ('d643e286-63cf-4136-9143-b0842cbbf97e', 20000.00, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Deposit', 'Pension money', '2025-09-25 11:00:00.771534', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 950948631676882);
INSERT INTO public.transactions VALUES ('2650ba0e-cf26-43a2-b68e-f9d61787f8f4', 120.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Withdrawal', 'Personal', '2025-09-25 11:00:09.29103', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 1475659723177);
INSERT INTO public.transactions VALUES ('93bce0b7-d6d4-4bb3-bf0a-3e4be372453c', 2000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'class fee', '2025-09-25 11:00:30.925157', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 541155552695839);
INSERT INTO public.transactions VALUES ('a2fb42ec-64f6-4ae0-a24d-52084e9ea892', 150.00, '89e221cd-2b08-47c5-a88f-3ceffa79fb9a', 'Withdrawal', 'bill', '2025-09-25 11:00:33.208201', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 753977953864428);
INSERT INTO public.transactions VALUES ('8e20f990-2047-4932-b28f-02c85f982531', 5000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'CS-2023', '2025-09-30 11:00:19.130175', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 112061715861664);
INSERT INTO public.transactions VALUES ('5479ef57-25b9-45de-bc6f-72874509c616', 30000.00, '6c66d02c-2753-4163-ae2a-9f2ffcd0574b', 'BankTransfer-Out', 'ew', '2025-09-30 11:00:29.271934', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 848103955486187);
INSERT INTO public.transactions VALUES ('5eab9f81-a96a-4149-8f20-9e717570f1ee', 30000.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'BankTransfer-In', 'ew', '2025-09-30 11:00:29.271934', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 166102234884462);
INSERT INTO public.transactions VALUES ('f32a4a51-ba0a-4657-b3fc-c72519737991', 150.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Deposit', 'bill', '2025-09-30 11:00:38.977817', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 350847010817628);
INSERT INTO public.transactions VALUES ('19b6529a-50d6-4ab2-a582-ff8ccd43b580', 4000.00, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Deposit', 'CS4023', '2025-09-30 11:00:50.255104', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 12670564410218);
INSERT INTO public.transactions VALUES ('655778d7-5dde-41ff-9a68-8a910976f7a9', 3000000.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Deposit', 'Lottery
', '2025-09-30 11:00:54.619648', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 617774751035050);
INSERT INTO public.transactions VALUES ('49c3fba8-e5fa-4062-94c4-a6afa9ff0174', 50000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Withdrawal', 'Personal', '2025-10-01 12:00:36.553954', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 512183828564429);
INSERT INTO public.transactions VALUES ('4128980f-92ab-4717-8f08-ad50a4086e23', 3452.04, '697a0943-3418-427b-9786-45b5c5066b71', 'Deposit', 'FD Interest - FD Account No: 28969810', '2025-10-01 12:00:43.79928', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 447173629890937);
INSERT INTO public.transactions VALUES ('793d4c2f-a4a3-4f8b-a705-c159058d55c1', 16.42, '0415f29e-fb5b-4756-baa6-bce59cab2be5', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 303055205144085);
INSERT INTO public.transactions VALUES ('f91aab83-ccc6-47fb-8b0c-20913dfa714f', 194.34, '17c9a664-3b42-456e-95e4-4bd73353f0e0', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 850463580367816);
INSERT INTO public.transactions VALUES ('a3f9411d-8d17-4c22-8431-f4c490b75865', 327.32, '1853d4ea-a229-4757-9a4c-f6f858351196', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 776054281425248);
INSERT INTO public.transactions VALUES ('7aab37c9-604d-450f-8e55-81d7fc5bb087', 8.42, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 317240988857549);
INSERT INTO public.transactions VALUES ('1c497c6e-7ed7-4aee-8d4b-72e480273b38', 201.42, '1dfe7946-7b05-4de1-8254-1528660baf18', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 863211849358325);
INSERT INTO public.transactions VALUES ('c3e0c714-678b-4ebb-811e-666533013300', 211.85, '2955457b-8207-4228-a3da-c9d5940c2095', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 736961287310226);
INSERT INTO public.transactions VALUES ('df0ee792-c3e4-4b3f-b185-f6a72c735edd', 715.19, '2dc6afc8-e2ce-4ab8-b6db-6d10bceff3da', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 472423773598434);
INSERT INTO public.transactions VALUES ('e5a3fea6-03c7-4e52-b890-cfe62413f0ab', 18134.61, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 300439545258593);
INSERT INTO public.transactions VALUES ('a3c6018e-b12f-4b33-aeb4-b5b11de115ee', 2626.30, '30159eb0-328d-4cf2-84a3-d7f51040ed22', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 939466635413761);
INSERT INTO public.transactions VALUES ('8c1fb536-eb22-4063-be4c-87d1135082a1', 1.25, '31d95fe1-7d2f-4d9e-81c1-b608131b7335', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 508162821027666);
INSERT INTO public.transactions VALUES ('2e8b12c1-49b6-45ea-bb5a-deecd94b4dc7', 381.51, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 653906849040788);
INSERT INTO public.transactions VALUES ('350a49c1-b665-4931-a1cb-afb119947d07', 201.74, '3aef91e8-f7b0-47a8-a03a-4c1770d74d30', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 180588237220902);
INSERT INTO public.transactions VALUES ('8b5b111a-7d77-41be-a34a-68196cde08a9', 199.27, '3b4fe46d-d998-4231-bf48-9552830244fe', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 352233747165098);
INSERT INTO public.transactions VALUES ('3d118132-ffc6-4e6a-9646-657ab140deb2', 5245.05, '4ae3fefd-a3d4-4133-b516-bddebdf3d49f', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 100824464975102);
INSERT INTO public.transactions VALUES ('7518344e-94e7-482d-9ef4-6919da72adf8', 461.08, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 941615040910335);
INSERT INTO public.transactions VALUES ('a4e8b4ec-a7d1-489c-b31a-7d19d04fe4c3', 3480.47, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 698712782341874);
INSERT INTO public.transactions VALUES ('d8a26909-ba8f-4aba-8c3e-272efd7ad0a8', 265.25, '6793b998-92c2-45bb-a4d4-1b84fefbc652', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 364385215933308);
INSERT INTO public.transactions VALUES ('83170ea9-668c-4f56-ac09-34a1baf0c429', 218.11, '697a0943-3418-427b-9786-45b5c5066b71', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 409400426293106);
INSERT INTO public.transactions VALUES ('50effdb3-2191-4e2b-b470-c825d3194dea', 2547.95, '6c66d02c-2753-4163-ae2a-9f2ffcd0574b', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 262024504799631);
INSERT INTO public.transactions VALUES ('13c79ba3-1b8f-4d9c-8f59-e3a8da8bb64a', 15.31, '7fe7a775-2411-423a-84fa-e3ed126ec6c3', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 506108059371422);
INSERT INTO public.transactions VALUES ('493b9d36-93bb-41ff-ab14-b07567fc55a0', 56.43, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 501966755585100);
INSERT INTO public.transactions VALUES ('18cab0c2-cd75-451b-a6e3-d66693faffe3', 657.53, '84f57e11-cd1b-40cf-b70b-e67a538ded88', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 875689577212028);
INSERT INTO public.transactions VALUES ('e8710e5f-be7e-49a1-9e96-aefeea37daac', 902.78, '89e221cd-2b08-47c5-a88f-3ceffa79fb9a', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 328312304574593);
INSERT INTO public.transactions VALUES ('03332b72-1f3f-4e03-b9c8-48954c9299b9', 41.79, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 44231671517482);
INSERT INTO public.transactions VALUES ('899bb209-b32f-4e2e-95a3-4226989080cf', 194.21, '99280df3-2bad-4c61-b069-bf6144235552', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 896377235427678);
INSERT INTO public.transactions VALUES ('0b735356-e6dd-4c3b-ac68-31e1b6c28ebc', 367.92, '9f195429-65fc-48c0-8a22-3216088f897e', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 567045709175344);
INSERT INTO public.transactions VALUES ('eb7d70a7-b997-4374-9a77-08c0422f951d', 101.93, 'a949c77a-bb3b-484f-9b3e-8d68a36deb87', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 134596110234990);
INSERT INTO public.transactions VALUES ('bc0a95a2-396c-4f43-b3ce-96ad84ee4f4e', 1137.69, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 703645514067453);
INSERT INTO public.transactions VALUES ('cfa8e7e6-a714-4dbd-81f5-2f32aad442bf', 16507.08, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 826078577813028);
INSERT INTO public.transactions VALUES ('bb1c28d4-8a05-40b9-83b7-acea913aac71', 357.99, 'b79aefad-de0e-4387-84cb-7a1234ce4ce7', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 654920081572042);
INSERT INTO public.transactions VALUES ('81cf8f79-c70f-467b-b00d-509e0c0d2600', 87.15, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 172657257757125);
INSERT INTO public.transactions VALUES ('b20990c1-3fb5-4f92-a383-895152527657', 17875.25, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 630487440943743);
INSERT INTO public.transactions VALUES ('165cb66f-db53-4675-9d77-7f55423236cf', 2024.54, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 386451591454718);
INSERT INTO public.transactions VALUES ('24c4092b-156d-46e5-89d7-b78cdd733b2d', 380.36, 'd38f3e7a-9414-40e4-b62f-47019c16be6b', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 921507035566734);
INSERT INTO public.transactions VALUES ('55f9953a-b7b8-475e-ae84-8f0379ce006c', 376.49, 'ded1f289-7f01-4135-b638-dd735d691229', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 754002259588908);
INSERT INTO public.transactions VALUES ('ac0477b7-b8d3-47bd-aa2e-bb7a950078c4', 578.76, 'dffecccc-565a-4b66-804c-1befa178b8f7', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 321236519467828);
INSERT INTO public.transactions VALUES ('4fd9ebf9-a511-4a36-9f2f-8e2fb1582c95', 49.48, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 711331509337458);
INSERT INTO public.transactions VALUES ('b5d390d2-4e7e-4699-876d-09981f333e78', 2903.14, 'e085d6e0-4e81-4dd5-b124-fae6a038a453', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 150115974656185);
INSERT INTO public.transactions VALUES ('203695b1-43b1-46c6-b8f3-6af9121023d7', 99.64, 'e260aeef-4836-4a35-bb19-3d109adba141', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 674937285693267);
INSERT INTO public.transactions VALUES ('861550e9-8b19-423b-aad7-681f98ddcb38', 665.67, 'f4a8e8d5-92af-421d-a437-dce94fd12638', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 16445299956168);
INSERT INTO public.transactions VALUES ('ebdbd285-517b-42b6-ae14-6b915c6151f8', 13.14, 'fb762c41-c883-4bba-9bcf-f59dfc07f042', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 278701965007133);
INSERT INTO public.transactions VALUES ('c6ee17bf-81a7-413c-b44c-a8d37424e0ee', 11.91, 'fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 731383191664147);
INSERT INTO public.transactions VALUES ('d998184c-1ceb-4846-9bb5-f30dd662388c', 506.60, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 984675138286840);
INSERT INTO public.transactions VALUES ('07b80c3d-ac63-4ad1-bbe1-010412139d87', 7.06, 'fde6ebe4-72be-4574-a470-999a365b1529', 'Interest', 'Monthly interest', '2025-10-01 12:00:43.830411', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 352175636066524);
INSERT INTO public.transactions VALUES ('1db35cc0-ea74-44de-8b9e-c3cd39d8ff65', 120000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Deposit', 'Deposit', '2025-10-05 12:00:03.743927', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 709664154399674);
INSERT INTO public.transactions VALUES ('8b05cce4-df1c-4316-9895-d7a401b9a01a', 43000.00, 'a6b1bdd7-e70e-4dd8-8621-397d69fb3300', 'Deposit', 'Depo', '2025-10-05 12:00:34.993277', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 540562305268937);
INSERT INTO public.transactions VALUES ('453af190-5088-4bc5-a0d2-a24132c55549', 99998.00, 'a6b1bdd7-e70e-4dd8-8621-397d69fb3300', 'Deposit', 'Created fixed deposit', '2025-10-05 12:00:47.856729', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 886871771666949);
INSERT INTO public.transactions VALUES ('0e15ba7d-456d-43a7-9110-90a17f10c22f', 250.00, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Deposit', 'bill', '2025-10-05 12:00:53.547095', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 239144726486050);
INSERT INTO public.transactions VALUES ('834ff41d-32c8-4ed5-bb03-36e4f7908cf1', 4602.73, '1853d4ea-a229-4757-9a4c-f6f858351196', 'Deposit', 'FD Interest - FD Account No: 64474239', '2025-10-10 12:00:10.270924', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 155684913455212);
INSERT INTO public.transactions VALUES ('39762a7f-b940-46ee-801e-92c528902603', 534.24, '30159eb0-328d-4cf2-84a3-d7f51040ed22', 'Deposit', 'FD Interest - FD Account No: 10630536', '2025-10-10 12:00:10.270924', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 661781006970861);
INSERT INTO public.transactions VALUES ('f983a4a7-c9d7-4952-acfb-34abd2f7ac11', 61643.84, 'd00aab8b-e75c-4cec-82b4-00bd1f0c8fbc', 'Deposit', 'FD Interest - FD Account No: 28892515', '2025-10-10 12:00:10.270924', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 924847258520052);
INSERT INTO public.transactions VALUES ('f644658c-3324-4704-9743-6b4c4000a1f5', 32.00, '7fe7a775-2411-423a-84fa-e3ed126ec6c3', 'Withdrawal', 'Rent ', '2025-10-10 12:00:14.312109', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 207370422381468);
INSERT INTO public.transactions VALUES ('7ae3a0a8-0a9f-4ea9-8b21-2c6b99a08f28', 50000.00, 'c6b21347-9458-4f2b-8b03-4c479c60315e', 'Withdrawal', 'bill payment', '2025-10-10 12:00:25.602868', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 937782650705623);
INSERT INTO public.transactions VALUES ('c07a6d86-69ed-42e7-a2a7-b23a9b706c65', 50000.00, '7fe7a775-2411-423a-84fa-e3ed126ec6c3', 'Deposit', 'Sallary', '2025-10-10 12:00:34.081973', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 227395809802058);
INSERT INTO public.transactions VALUES ('b1222d0e-e0e2-4224-85bb-e9b3bb79d064', 25000.00, '7fe7a775-2411-423a-84fa-e3ed126ec6c3', 'Withdrawal', 'bill', '2025-10-10 12:00:56.321007', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 194474255203807);
INSERT INTO public.transactions VALUES ('16304989-0d51-4ba7-82ad-0ae067681a6a', 500.00, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Withdrawal', 'Private', '2025-10-10 12:01:00.652885', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 502323487501285);
INSERT INTO public.transactions VALUES ('53aa6fa2-fcf5-444d-a03e-b259fe8d4535', 11506.85, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Deposit', 'FD Interest - FD Account No: 93458513', '2025-10-15 12:00:07.904117', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 867011303219614);
INSERT INTO public.transactions VALUES ('6ca11b78-6896-43e0-a4f4-2863406619f0', 500000.00, '4ef7006d-a92a-4f64-ac22-74a06d48b1c2', 'Deposit', 'For FD', '2025-10-15 12:00:38.668156', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 2693560615524);
INSERT INTO public.transactions VALUES ('1a6278ab-b288-434a-bbf5-e03fe6028edf', 20000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Deposit', 'Personal', '2025-10-15 12:00:38.75903', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 842014315567517);
INSERT INTO public.transactions VALUES ('7b3601b9-bf23-4845-ae74-60e8acf6edab', 200000.00, 'b646dd25-7775-417f-a216-30a84aa9c451', 'Withdrawal', 'Buy a house', '2025-10-15 12:00:56.668066', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 251598811095782);
INSERT INTO public.transactions VALUES ('33162b85-399c-473b-9f43-06aca4860387', 500000.00, '0415f29e-fb5b-4756-baa6-bce59cab2be5', 'Deposit', 'Lottery', '2025-10-15 12:01:02.352722', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 648676761874506);
INSERT INTO public.transactions VALUES ('b2c9623b-fdf2-4de9-9258-bf226bb5ec81', 500.00, '4dcf9c4f-2bec-49f9-a336-5e45cce1601b', 'Deposit', 'Personal', '2025-10-20 12:00:04.300559', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 923315215043769);
INSERT INTO public.transactions VALUES ('b5bd2598-d8e5-4081-b13b-161454b4bc2d', 3400.00, '20a94040-fbf0-4e7a-ae5f-c6e766a134ca', 'Withdrawal', 'Salo', '2025-10-20 12:01:09.029804', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 889560118756351);
INSERT INTO public.transactions VALUES ('fff4ff32-3ef6-48d5-a7e7-c5f26ea2098a', 10000.00, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Deposit', 'Saving', '2025-10-20 12:01:09.480322', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 490023690755244);
INSERT INTO public.transactions VALUES ('6e18bd6d-619f-47e7-baa7-09dcf9157d76', 50000.00, '6c66d02c-2753-4163-ae2a-9f2ffcd0574b', 'Withdrawal', 'betting lost', '2025-10-20 12:01:23.311164', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 230336094591671);
INSERT INTO public.transactions VALUES ('b222dda2-4566-4d56-b766-423cf445a3a8', 4100.00, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'Deposit', 'Saving', '2025-10-20 12:01:56.393085', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 777410457994352);
INSERT INTO public.transactions VALUES ('66a0918f-167c-4e33-82e6-581ada93bc17', 500400.00, '6c66d02c-2753-4163-ae2a-9f2ffcd0574b', 'Deposit', 'Stolen money', '2025-10-23 08:00:10.624144', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 266200862973728);
INSERT INTO public.transactions VALUES ('7260e192-9ee3-41c9-a174-18ae262ea7e7', 20000.00, '6c66d02c-2753-4163-ae2a-9f2ffcd0574b', 'Withdrawal', 'For the rocket', '2025-10-23 08:00:30.980036', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 768580533198630);
INSERT INTO public.transactions VALUES ('7939d4fb-1adf-4fb5-aae7-ff1aca706696', 500000.00, '2effb977-c5cb-43cb-9c5e-7db80de361e4', 'Withdrawal', 'Bill', '2025-10-23 08:00:42.47741', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 988680041319605);


--
-- TOC entry 3803 (class 0 OID 31107)
-- Dependencies: 250
-- Data for Name: user_login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.user_login VALUES ('9fdc2462-7532-40da-82d0-2b8a6aad1128', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'system1', '$2y$10$2tcVhTKEJ4NRts4lmw5NqOxqhCvQQ94sXMraIyK1YqWZw2Zga9vJW', '2025-09-18 06:59:15.461996', '2025-09-18 06:59:15.461996', '2025-09-18 06:59:15.461996', NULL, NULL, 'active');
INSERT INTO public.user_login VALUES ('e67ce6c6-bb0d-46cf-a222-860e548822a0', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'agent3', '$2b$12$w8czX6DDYjBiJvdIjOpxVOatGl32Ca4nX40N9A2fWvsPjPTltraB6', '2025-09-18 14:04:14.712609', '2025-09-18 14:04:14.712609', '2025-08-04 10:45:38.225101', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active');
INSERT INTO public.user_login VALUES ('86295c07-2139-4499-9410-d729b012cfb7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'agent4', '$2b$12$K4ZpGK2cPR0kivNqhtVRzO6vkOSkFKOkx/zNiAKuREJEqVu.BQ.y2', '2025-09-18 14:18:45.238594', '2025-09-18 14:18:45.238594', '2025-08-04 10:45:38.230918', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active');
INSERT INTO public.user_login VALUES ('e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd', 'de9dc531-11bf-4481-882a-dc3291580f60', 'agent1', '$2b$12$14vPB5UI74Cs/6gIah46wecLcncl4.0qcBQ9XqtXLkFvYj9e5qYIC', '2025-09-18 07:09:21.535303', '2025-09-18 07:09:21.535303', '2025-08-04 10:45:38.23354', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.user_login VALUES ('8e940780-67c7-42e8-a307-4a92664ab72f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'agent2', '$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K', '2025-09-18 07:19:23.418837', '2025-09-18 07:19:23.418837', '2025-08-04 10:45:38.235628', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');


--
-- TOC entry 3804 (class 0 OID 31117)
-- Dependencies: 251
-- Data for Name: user_refresh_tokens; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.user_refresh_tokens VALUES ('678d5f69-4663-47e8-bea8-eb083701dcbb', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2c5ed2099841278465300796097605bd7bf4da5a214a01e2ae08325b458990e1', '2025-09-25 01:31:09.924771', false, NULL, NULL, '2025-09-18 07:01:09.83433', '2025-09-18 07:01:09.83433', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e97ab5ee-d733-40d9-adb2-60769303db42', 'de9dc531-11bf-4481-882a-dc3291580f60', 'd63c15766ca38fb841e756e319dfe492e32685c496ebcd232514547aea65f97f', '2025-09-25 01:48:25.920403', false, NULL, NULL, '2025-09-18 07:18:25.687636', '2025-09-18 07:18:25.687636', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d278e2a6-75be-4022-a759-13b93a800452', 'de9dc531-11bf-4481-882a-dc3291580f60', 'dbea4ade6837a2361f4e00caea0b70457f8d213ca1576a2356ffc5ae85090017', '2025-09-25 08:32:15.671082', false, NULL, NULL, '2025-09-18 14:02:15.403076', '2025-09-18 14:02:15.403076', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('3fb7573a-2b5d-4da7-ad2f-e55831856fb6', 'de9dc531-11bf-4481-882a-dc3291580f60', '7c6563ffd9b3a8edb58c1b1a5a741da3c7075e39fce1a28deabd7947aa522e9d', '2025-09-28 18:42:51.787149', false, NULL, NULL, '2025-09-22 00:12:51.514948', '2025-09-22 00:12:51.514948', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('136e984c-4dbf-4d50-b831-1b0316e979ed', 'de9dc531-11bf-4481-882a-dc3291580f60', '34853a230f98bff61d707354caa89a12fe71457b0be2ad500786d05083b76792', '2025-09-28 18:43:31.502704', false, NULL, NULL, '2025-09-22 00:13:31.270299', '2025-09-22 00:13:31.270299', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a2791147-04b2-4075-aba5-5904ee58207a', 'de9dc531-11bf-4481-882a-dc3291580f60', '91d5e79c9b6fac6b12fbfc2098358744b47ba10c7935f5d33d856ab69f946e83', '2025-09-28 18:49:04.876643', false, NULL, NULL, '2025-09-22 00:19:04.642045', '2025-09-22 00:19:04.642045', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c353bc1d-57d7-4040-a54a-e160fa2bfa90', 'de9dc531-11bf-4481-882a-dc3291580f60', '121bfaae54c9fe99f0691f903b4fabe8764935a5f6c42f1bdfac225f8e6cd593', '2025-09-28 18:51:39.066589', false, NULL, NULL, '2025-09-22 00:21:38.833204', '2025-09-22 00:21:38.833204', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6a0e5bbf-d470-43f5-9175-0f7b6164aaaf', 'de9dc531-11bf-4481-882a-dc3291580f60', 'f47121511925c07e5582df3cfd6650592d8937602ce052cd26b5f8672c1fabcd', '2025-09-29 02:59:33.63813', false, NULL, NULL, '2025-09-22 08:29:33.021735', '2025-09-22 08:29:33.021735', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f9fa1fc8-515f-4882-8bff-52d69748c972', 'de9dc531-11bf-4481-882a-dc3291580f60', '89baf09f5df5970e519394d2b9a6ecdb31c04cc206d1a30e768f5c0c425b5fe9', '2025-09-29 03:06:07.235559', false, NULL, NULL, '2025-09-22 08:36:06.737813', '2025-09-22 08:36:06.737813', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('93f69804-da1c-4fc1-abec-cea2d75695ad', 'de9dc531-11bf-4481-882a-dc3291580f60', '3a1559798a58ecc48c911dd8cbd8e0366c0c30c6f46880818ba8535e476bc665', '2025-09-29 03:08:45.674032', false, NULL, NULL, '2025-09-22 08:38:45.254825', '2025-09-22 08:38:45.254825', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('27a65582-f6c4-4a1e-b820-e6c91bc11893', 'de9dc531-11bf-4481-882a-dc3291580f60', '5c654b49dc31523bd6370d4bdb9e1bf0b97495eff5dcf352ef395f45fb65cd68', '2025-09-29 03:08:45.827703', false, NULL, NULL, '2025-09-22 08:38:45.414417', '2025-09-22 08:38:45.414417', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('be9e85be-a678-48b7-8f07-35b8a9032d79', 'de9dc531-11bf-4481-882a-dc3291580f60', '0dce2441dd43d3ea78e752b45cac5bff384eef6a65e4cc0d1e1f47259571d168', '2025-09-29 03:42:44.155956', false, NULL, NULL, '2025-09-22 09:12:43.885577', '2025-09-22 09:12:43.885577', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f7e2b444-aeb6-4aaf-b993-06bddc2dd2b2', 'de9dc531-11bf-4481-882a-dc3291580f60', '71d6c665af6d4f1d3f233a67ae851eacaa49830b85bd8150b17a9609e8b2be03', '2025-09-29 03:45:19.048552', false, NULL, NULL, '2025-09-22 09:15:18.79815', '2025-09-22 09:15:18.79815', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0d6fc872-aa8f-4426-97a8-d5d3777dc2de', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e4e0b61e28762577108affb88a408d224d8482c16f44241cca85e7f2840099df', '2025-09-29 03:56:09.182414', false, NULL, NULL, '2025-09-22 09:26:08.907774', '2025-09-22 09:26:08.907774', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f83fdac6-7ba2-473e-a23b-bfecbea05e26', 'de9dc531-11bf-4481-882a-dc3291580f60', 'dfadf9782ddfb37b5adfcc575911c1d1936f4c7a0f38463e815fe785eb1cd2ca', '2025-09-29 03:58:10.789453', false, NULL, NULL, '2025-09-22 09:28:10.537577', '2025-09-22 09:28:10.537577', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('038360be-1bc2-4ba3-a773-c482cac9dc5e', 'de9dc531-11bf-4481-882a-dc3291580f60', '80b3c0251d9bca24d1538e7ec38f0e70dba1514df1c8a44b7d68418b78502fdc', '2025-09-29 03:58:51.847145', false, NULL, NULL, '2025-09-22 09:28:51.596043', '2025-09-22 09:28:51.596043', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('452572c5-87d2-4357-9d00-c0f595f1503c', 'de9dc531-11bf-4481-882a-dc3291580f60', '498076d68c79a1bea597d02b1e0e98be3555867f4f075fe8e2a700a3c968d9b5', '2025-09-29 04:00:11.10285', false, NULL, NULL, '2025-09-22 09:30:10.841071', '2025-09-22 09:30:10.841071', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('2fd8d0fb-402c-4073-8025-3bdc8dc59f62', 'de9dc531-11bf-4481-882a-dc3291580f60', '1f432c987b70bcf47c1501c6fed46fb3546cc925cf3978f67fa6f68ee2a0998a', '2025-09-29 04:00:18.180009', false, NULL, NULL, '2025-09-22 09:30:17.911547', '2025-09-22 09:30:17.911547', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4f90396f-f863-4a40-af18-4160f822483f', 'de9dc531-11bf-4481-882a-dc3291580f60', '92da0842ac9c89d72ecf8e2d5411bdf30874ed73490c03ab5766cf91951aa8d0', '2025-09-29 04:03:49.141391', false, NULL, NULL, '2025-09-22 09:33:48.885342', '2025-09-22 09:33:48.885342', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f5074ff1-960f-48b0-b367-71148c111140', 'de9dc531-11bf-4481-882a-dc3291580f60', '2bd361d4c9f525bb804ece0bce16bf2d86f7f0a94cdc09110f848231330c97d4', '2025-09-29 04:04:04.457679', false, NULL, NULL, '2025-09-22 09:34:04.219523', '2025-09-22 09:34:04.219523', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7eafd257-742b-42c6-947b-1fa989fc135a', 'de9dc531-11bf-4481-882a-dc3291580f60', '3734e29ccc09feab760c25cd623b18dcacba8fa82e23dfbb85d4e6678e6a3599', '2025-09-29 04:04:30.287874', false, NULL, NULL, '2025-09-22 09:34:30.056893', '2025-09-22 09:34:30.056893', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ecadd80a-ba04-4c99-a694-581a9d622c8b', 'de9dc531-11bf-4481-882a-dc3291580f60', '209d4c6deb979daad93a2297263fb87698c98f2842e003f79bb8e55f31de30e1', '2025-09-29 04:09:29.916281', false, NULL, NULL, '2025-09-22 09:39:29.663651', '2025-09-22 09:39:29.663651', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('bc638332-d4f7-4a15-949e-6c405b348756', 'de9dc531-11bf-4481-882a-dc3291580f60', '420cf564f8bc00981e2725c26569793b322546123237ff422fe4d67aea7221f0', '2025-09-29 04:10:00.31555', false, NULL, NULL, '2025-09-22 09:40:00.06446', '2025-09-22 09:40:00.06446', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('2d2a7dd2-2af3-42ce-b584-c83bfa10b4eb', 'de9dc531-11bf-4481-882a-dc3291580f60', '8fd76cc303f396056159bc3b82a4d0f3449339462b3c146e4cfa1a13ed3e0b00', '2025-09-29 04:11:12.980692', false, NULL, NULL, '2025-09-22 09:41:12.726653', '2025-09-22 09:41:12.726653', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e7291f88-f47d-4305-9c68-3bf2c262ea4b', 'de9dc531-11bf-4481-882a-dc3291580f60', '4be6f6eceab5d288a86e6da8714c619f06942ad292c9768840aaa0c2f2e780a1', '2025-09-29 04:11:26.516601', false, NULL, NULL, '2025-09-22 09:41:26.253239', '2025-09-22 09:41:26.253239', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('315e5c13-87c3-4757-b3ca-44a0191f212d', 'de9dc531-11bf-4481-882a-dc3291580f60', '06a8a3fc2f35d01faf74a95364af7a08fbdc32505e97a0784be75ec35253923f', '2025-09-29 04:13:22.660165', false, NULL, NULL, '2025-09-22 09:43:22.383229', '2025-09-22 09:43:22.383229', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('3a776b49-cd97-439f-984f-9c8124fb5b51', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e2df27d44cb578b95153b74c9d3509ab75651316b28c259f64bfab6d4be7e52a', '2025-09-29 04:44:56.640162', false, NULL, NULL, '2025-09-22 10:14:56.408403', '2025-09-22 10:14:56.408403', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('1dc04405-e044-4930-be93-6c1504cc0827', 'de9dc531-11bf-4481-882a-dc3291580f60', '2781687fa9a545ca8f7f1fd838eaf74b647110d9426bbe9da6015282f0b93f8e', '2025-09-29 04:45:16.804358', false, NULL, NULL, '2025-09-22 10:15:16.572024', '2025-09-22 10:15:16.572024', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('00f58b70-6075-4717-877b-3cbeb8495576', 'de9dc531-11bf-4481-882a-dc3291580f60', 'a01a4169dbcffdec13fe386be5d7cb6fd55a21a0715b281ff7d48abbcadf5632', '2025-09-29 04:48:53.234741', false, NULL, NULL, '2025-09-22 10:18:52.975545', '2025-09-22 10:18:52.975545', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fcd57137-8f89-442f-a621-2cdce8b201a8', 'de9dc531-11bf-4481-882a-dc3291580f60', '5ecbd1d4705ab49222d29b37a543bda087b40450e2fd8405c4e985e44e934010', '2025-09-29 04:50:50.928659', false, NULL, NULL, '2025-09-22 10:20:50.697348', '2025-09-22 10:20:50.697348', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('850b82ed-f3e0-4133-81a1-e50c42fbcbb8', 'de9dc531-11bf-4481-882a-dc3291580f60', 'baa200ee2738007a6f71bc91969e8f5aaf71b5bc5769f6caed82b60e8c75ec87', '2025-09-29 04:51:08.492127', false, NULL, NULL, '2025-09-22 10:21:08.25983', '2025-09-22 10:21:08.25983', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('644e361f-5830-483d-8840-ed404a211286', 'de9dc531-11bf-4481-882a-dc3291580f60', 'ea8ad949983640055e03ed6c0d1b447067e23d3a7ff8dfb5a317b582008b33c8', '2025-09-29 04:54:36.97248', false, NULL, NULL, '2025-09-22 10:24:36.720264', '2025-09-22 10:24:36.720264', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('13f033ee-a45e-4b0f-bfbf-8db1aa4f5965', 'de9dc531-11bf-4481-882a-dc3291580f60', '7c34c30bbb9a0c1d2689405240c10892af2d0ba7705f3943e96eff887a3e72a3', '2025-09-29 04:54:37.117265', false, NULL, NULL, '2025-09-22 10:24:36.885382', '2025-09-22 10:24:36.885382', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4d2ed287-427b-4a7d-adda-934e55377cd2', 'de9dc531-11bf-4481-882a-dc3291580f60', '8e2a9574dfc936eb8fe22b7d621efb5dd8e175b3eca846ef77053b2618a8325c', '2025-09-29 06:28:36.803607', false, NULL, NULL, '2025-09-22 11:58:36.551429', '2025-09-22 11:58:36.551429', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4c823fdc-11da-4e0f-afce-69a5d731dac1', 'de9dc531-11bf-4481-882a-dc3291580f60', '45438d30bd71039871f2cd26549c2df35e2484cce32900d78f8a18bb070a24f9', '2025-09-29 07:02:14.453181', false, NULL, NULL, '2025-09-22 12:32:14.212019', '2025-09-22 12:32:14.212019', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a2a3bd18-3f54-47d8-be9e-c697cf4fbce4', 'de9dc531-11bf-4481-882a-dc3291580f60', 'f055e569a05727f4df20aa54aac95d7084e016745186eb377827eef10be815f1', '2025-09-29 07:12:22.104072', false, NULL, NULL, '2025-09-22 12:42:21.849122', '2025-09-22 12:42:21.849122', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('693603bd-ad6a-4063-aa2b-c7118337e35c', 'de9dc531-11bf-4481-882a-dc3291580f60', '6dcc75083cfbc9df38f6afbbe0414a199f425bc544c5080901d90a0e58a37a15', '2025-09-29 07:15:53.246691', false, NULL, NULL, '2025-09-22 12:45:52.987045', '2025-09-22 12:45:52.987045', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fc6f15eb-ad26-44f7-b117-baacf3f465c8', 'de9dc531-11bf-4481-882a-dc3291580f60', 'd556f3ef026c1dd03b5093003f2f78ffddb0eec8879e8f4fbbb64779457016f2', '2025-09-29 07:21:19.635361', false, NULL, NULL, '2025-09-22 12:51:19.380084', '2025-09-22 12:51:19.380084', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('b139f19b-344d-4b57-beb4-56a84f7e2696', 'de9dc531-11bf-4481-882a-dc3291580f60', '19bf8e989d5db590e2d914a32db3a5ae7dcc6bb89fe2434b20858f9b0c474d5b', '2025-09-29 07:22:08.662156', false, NULL, NULL, '2025-09-22 12:52:08.409941', '2025-09-22 12:52:08.409941', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('530d5cb2-24f7-4e3f-ba8e-e2741514053e', 'de9dc531-11bf-4481-882a-dc3291580f60', '2a0b8ed46142e2f0ede7192a0cd43f110ce05701e7d51e6fc041043a5f6bf53a', '2025-09-29 07:24:08.892925', false, NULL, NULL, '2025-09-22 12:54:08.62085', '2025-09-22 12:54:08.62085', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e0a578e2-6a51-4825-81ad-f8e1366ad254', 'de9dc531-11bf-4481-882a-dc3291580f60', '47467934e5ffbafd847b46d47983b47cfa6022e516d98ead7065a0cbdbcaa735', '2025-09-29 07:25:40.118696', false, NULL, NULL, '2025-09-22 12:55:39.884308', '2025-09-22 12:55:39.884308', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('2a36bf3e-d485-4e47-b07c-1c6b63a8a14a', 'de9dc531-11bf-4481-882a-dc3291580f60', 'caef878c40cd624fc7d870413b2c5a1b013b5da3b6a9eb2c3ffe0647d1c4727c', '2025-09-29 07:51:08.869286', false, NULL, NULL, '2025-09-22 13:21:08.392618', '2025-09-22 13:21:08.392618', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a900dbb1-e3ad-47a2-a94f-d0f8d81b9bc0', 'de9dc531-11bf-4481-882a-dc3291580f60', 'f00a006bc92462a0600894fe7b2962902b49cb3a014195b3dcd0c60f56baa2e4', '2025-09-29 09:25:55.064702', false, NULL, NULL, '2025-09-22 14:55:54.79285', '2025-09-22 14:55:54.79285', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e96c8083-2b22-47a9-8183-df9129e851c6', 'de9dc531-11bf-4481-882a-dc3291580f60', '773fdb451c507f16ae1fb9bc00dc3adcc5cbb6cd298bf8aa4088736c5e076228', '2025-09-29 09:32:07.283396', false, NULL, NULL, '2025-09-22 15:02:07.053462', '2025-09-22 15:02:07.053462', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('1b2e2b3c-9ba8-47b6-89ba-e0335e206faf', 'de9dc531-11bf-4481-882a-dc3291580f60', '148de9081d97afe50e648a6d286a5e9b451fb5be5592a277214591a511ea690a', '2025-09-29 09:32:34.491253', false, NULL, NULL, '2025-09-22 15:02:34.238956', '2025-09-22 15:02:34.238956', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ab7d688e-cb28-40d5-8bbc-f0ec85547173', 'de9dc531-11bf-4481-882a-dc3291580f60', '588c2e70b71df89c4a4946fcffd3b0184560544a4c40899e55fbf80834cfb8fc', '2025-09-29 09:34:55.16318', false, NULL, NULL, '2025-09-22 15:04:54.918854', '2025-09-22 15:04:54.918854', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('65ef63d9-c699-4601-b0ed-4dc5c8f65daf', 'de9dc531-11bf-4481-882a-dc3291580f60', 'd70cc7456e81e084f3dc6d8ddc4bd2e0db2ebd667a5ec83320d62e6a6fb6a95e', '2025-09-30 10:35:23.587345', false, NULL, NULL, '2025-09-23 16:05:23.126818', '2025-09-23 16:05:23.126818', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('abf03ac8-e08a-4d47-94c6-67624d30ec38', 'de9dc531-11bf-4481-882a-dc3291580f60', '4fe70cd217464782e64528e77905dccb32246e30d441b17f6b0ab72f9797c0be', '2025-09-30 10:38:08.732006', false, NULL, NULL, '2025-09-23 16:08:08.48046', '2025-09-23 16:08:08.48046', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('8a949d63-3b01-41f6-bac6-0f8cf4a570e9', 'de9dc531-11bf-4481-882a-dc3291580f60', '19ac11c2be5c60e6afc5746d5db0b17910316c050dcee3af1795704691a7c816', '2025-09-30 10:45:51.915646', false, NULL, NULL, '2025-09-23 16:15:51.642926', '2025-09-23 16:15:51.642926', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c0fda872-78b9-42b7-b0ba-d665a6021cfd', 'de9dc531-11bf-4481-882a-dc3291580f60', 'a3873d3a483128eb057e9160687b47fc1857edcb638ac1c5b3575f4960b51b4e', '2025-09-30 10:55:24.526677', false, NULL, NULL, '2025-09-23 16:25:24.27206', '2025-09-23 16:25:24.27206', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7960636f-f314-4d0b-86ae-1d7218ad9cc1', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e11463e20934042d76ce16f2bce19a3ba2436b2d99ddec7d006ded8f992cb40d', '2025-09-30 10:59:03.252781', false, NULL, NULL, '2025-09-23 16:29:03.000119', '2025-09-23 16:29:03.000119', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0b3bb9a9-120b-4cf5-a73d-31742260c53d', 'de9dc531-11bf-4481-882a-dc3291580f60', 'c5711e1700590c619f5704eeeacb4071992575b66d4c7198d93ff2e28bea0e33', '2025-09-30 11:00:35.181193', false, NULL, NULL, '2025-09-23 16:30:34.941337', '2025-09-23 16:30:34.941337', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ab51d161-7dcb-4e8b-94db-39ca43bded9f', 'de9dc531-11bf-4481-882a-dc3291580f60', '7d4eb8e4f96b53437dc694a26f22e3d1d120d756a8dda00539de077a35ce29a7', '2025-09-30 11:01:04.77882', false, NULL, NULL, '2025-09-23 16:31:04.536494', '2025-09-23 16:31:04.536494', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('b311f611-7d61-4541-b662-e0b459297f63', 'de9dc531-11bf-4481-882a-dc3291580f60', 'b01d726a600a87da527872df5339326fc5b4cf1689ce3a22d4592a4627ace999', '2025-09-30 11:04:51.940308', false, NULL, NULL, '2025-09-23 16:34:51.6875', '2025-09-23 16:34:51.6875', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('17cb2bff-b4b5-4acf-8cc9-98797a05b332', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e3a88cc4b0949bd4e4e4202cfaaf292516a7adcd793669ca29807d1fcf64b917', '2025-09-30 11:09:28.157569', false, NULL, NULL, '2025-09-23 16:39:27.905343', '2025-09-23 16:39:27.905343', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('42a7c414-ed8e-46e6-b714-6e54a5d7345d', 'de9dc531-11bf-4481-882a-dc3291580f60', 'baf4603ee2a6196bfe38e3649497345b99a25fc6a01e283eeb8c65a812ae69f0', '2025-09-30 11:18:10.592943', false, NULL, NULL, '2025-09-23 16:48:10.340503', '2025-09-23 16:48:10.340503', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9e795957-1879-4eb4-abe3-4406216cc532', 'de9dc531-11bf-4481-882a-dc3291580f60', '12ee9cec6f628fc68824d379211a8444eaf5c62ca06d40af3441b870b0ab6cb8', '2025-09-30 11:23:14.773314', false, NULL, NULL, '2025-09-23 16:53:14.520733', '2025-09-23 16:53:14.520733', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('de8111b5-ce5c-4836-878f-f0605dab6e5b', 'de9dc531-11bf-4481-882a-dc3291580f60', '863a07b4aeec3a88c8d580f53b1935e482c44f15ea68709e9f763b8ec52590fc', '2025-09-30 12:52:57.782635', false, NULL, NULL, '2025-09-23 18:22:57.486665', '2025-09-23 18:22:57.486665', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0c4f5f59-7b8a-4bf2-9926-01af68a2c51f', 'de9dc531-11bf-4481-882a-dc3291580f60', '549ea34c9ef4ed499780c0b01567d0345b3e148b55b70bc8417f2f1906575191', '2025-09-30 12:57:18.47642', false, NULL, NULL, '2025-09-23 18:27:18.244325', '2025-09-23 18:27:18.244325', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('89798fca-92cc-4793-91b0-0e702705e9bc', 'de9dc531-11bf-4481-882a-dc3291580f60', '649d8ab338a6eb55245448e2c4d6ceca4b9c7eb5a45085f68de9dc7650d4433d', '2025-09-30 13:28:43.307566', false, NULL, NULL, '2025-09-23 18:58:43.045183', '2025-09-23 18:58:43.045183', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fe0ac8d6-887b-457c-a447-67c399f3e267', 'de9dc531-11bf-4481-882a-dc3291580f60', '5bf917328a85e584ac56db5b3dd0fc06762b8aee11e184afed284966258d48da', '2025-09-30 13:33:40.988626', false, NULL, NULL, '2025-09-23 19:03:40.715682', '2025-09-23 19:03:40.715682', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5b7ec7e1-9410-4c6e-84e3-fa253d7ec816', 'de9dc531-11bf-4481-882a-dc3291580f60', '8775d732301019a3a724c87ad1c62bc1b16c64264fab0d0ff3651a2628a38d54', '2025-09-30 13:36:33.789978', false, NULL, NULL, '2025-09-23 19:06:33.509643', '2025-09-23 19:06:33.509643', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('aa168f18-ff15-41a9-9b29-b4e392ae3380', 'de9dc531-11bf-4481-882a-dc3291580f60', 'bd4a4aa342a0834b958adbeefd44a9f2aa359d428a8c8498f3deb12fd933e062', '2025-09-30 13:39:20.207226', false, NULL, NULL, '2025-09-23 19:09:19.97633', '2025-09-23 19:09:19.97633', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5b3015bb-3be9-4101-beb2-cd5863c14613', 'de9dc531-11bf-4481-882a-dc3291580f60', '5d97dd7c0bb2b6d7d3f6e8eff3610bd98f5ede65e3b1c5cdb84c04e32b4b76fb', '2025-09-30 13:48:56.240045', false, NULL, NULL, '2025-09-23 19:18:55.954682', '2025-09-23 19:18:55.954682', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6f5d6c95-cbfb-41c1-90b0-d0887aa84214', 'de9dc531-11bf-4481-882a-dc3291580f60', 'd2cf6ceb0e36ffb65d23597098698449309f9a79dd3b377f0ca7f0c3a60151f5', '2025-10-01 09:22:03.554038', false, NULL, NULL, '2025-09-24 14:52:03.297909', '2025-09-24 14:52:03.297909', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('861a073a-5834-4aed-8fbe-d2ebeb46cd7f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4fb8821f9a1919e7f5430c0ee4b75ed98b8f434038b3bd339cb140437c71348b', '2025-10-01 09:26:02.515441', false, NULL, NULL, '2025-09-24 14:56:02.283902', '2025-09-24 14:56:02.283902', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0519e47e-4e53-47f5-95df-408a868374a9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'd16a2004c95e89198cac3b5a189811739c5502fd901d46dc585ee88d3bb4bb94', '2025-10-01 11:06:50.584446', false, NULL, NULL, '2025-09-24 16:36:50.333405', '2025-09-24 16:36:50.333405', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6489b42d-3e14-44fb-8853-b361ba3517c9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '1a160d7875edbfa2ca0b9feb22e823ea7918d4cf591690f820ab644ed480b08c', '2025-10-01 11:27:29.651773', false, NULL, NULL, '2025-09-24 16:57:29.401124', '2025-09-24 16:57:29.401124', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('37b839a8-7d84-4819-9366-cc348f8e3e2f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e02d8d6a7efafc43b2b6c1a23ebaf7bb0deed5bc863f39314675a6f2a75efe51', '2025-10-01 11:58:12.592011', false, NULL, NULL, '2025-09-24 17:28:12.337543', '2025-09-24 17:28:12.337543', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('b523d981-9798-4246-91c1-6fff8cdb4c71', 'de9dc531-11bf-4481-882a-dc3291580f60', '0d431bf43d49568b361d6aa2ddeea27cd9c187b3e815d6bc828e8a6532800175', '2025-10-02 03:30:08.902794', false, NULL, NULL, '2025-09-25 09:00:08.650338', '2025-09-25 09:00:08.650338', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('3f4378d9-47e4-45e7-8366-1e88a9683613', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'ccc8bf331c00e5f09e03e156e9e65a9568e79e990984db3ed3edf99f36247c80', '2025-10-02 18:08:09.235012', false, NULL, NULL, '2025-09-25 23:38:08.981071', '2025-09-25 23:38:08.981071', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('75695395-e908-4468-9875-2fc3fcd582c7', 'de9dc531-11bf-4481-882a-dc3291580f60', '6f76f908b76c5b448ab18e5d9c19378cb725f2bd987c329d917be6397603705f', '2025-10-08 13:33:50.943186', false, NULL, NULL, '2025-10-01 19:03:50.681561', '2025-10-01 19:03:50.681561', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4defab7f-c84a-4557-909f-710b339d00ba', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3d6812b2030475e7f7aca2c2284bde278b28245df6fa5c0e89c01fae3234bbbf', '2025-10-08 13:52:27.324012', false, NULL, NULL, '2025-10-01 19:22:27.072102', '2025-10-01 19:22:27.072102', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c7c0cc16-ef60-40e9-89a8-366e893b4364', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'fbe6fb1b3c9f4df36397503eec1942d8a5f78d6369af6e8fafa043deba774430', '2025-10-08 15:18:39.464485', false, NULL, NULL, '2025-10-01 20:48:39.172461', '2025-10-01 20:48:39.172461', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('afe1da4a-5970-4f4e-8e61-0c9a1057ff0e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '47b4f31d302e3f8eb181de8c1eb5c88ce5f4f6cb2068b22548d477d87b03dbdc', '2025-10-09 00:34:38.626212', false, NULL, NULL, '2025-10-02 06:04:38.355053', '2025-10-02 06:04:38.355053', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('775a1f86-ad43-4e75-add4-6889d135499d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2b241386768769145aec81f40960a132f51a8cf7bf661a2f8b1d1781810b2ab8', '2025-10-09 01:11:27.483771', false, NULL, NULL, '2025-10-02 06:41:27.227646', '2025-10-02 06:41:27.227646', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9858aea0-f40c-4170-a340-1fa6b2429b21', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'bc4abceaf75d4dde1620c12701b85b550475372826d32dc3ff7ad289f7ccb423', '2025-10-09 01:15:00.679227', false, NULL, NULL, '2025-10-02 06:45:00.428995', '2025-10-02 06:45:00.428995', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c786402e-e8a8-4690-8ee2-98c9ea1c79d0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '27f40e16e24343662bd6a1c7edcb05bd4fa3989d1ae1332161ec6a48bae2723d', '2025-10-10 11:54:01.780459', false, NULL, NULL, '2025-10-03 17:24:01.505017', '2025-10-03 17:24:01.505017', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('de4ee8cd-2438-4aba-8a74-d9e65efa4772', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '329304329b77add51998aac4946d69baa02cfdbb1c2c45fa0c94d2d943a810b1', '2025-10-10 16:55:06.248696', false, NULL, NULL, '2025-10-03 22:25:05.998265', '2025-10-03 22:25:05.998265', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('cef40768-69b7-4a4f-a542-fde4497f5028', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '97d7c6c51d9aeacb19e50b0352d2820d169027a31333ce4cac06d910962cae18', '2025-10-11 00:26:39.148669', false, NULL, NULL, '2025-10-04 05:56:38.896525', '2025-10-04 05:56:38.896525', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0476f7f1-e62b-4d7f-b027-e38e53daf41d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7513f8defde24df8c63e548cfa7ecdeac28fd3f3258d2e5398ca3e90f71d7b67', '2025-10-11 04:47:10.187612', false, NULL, NULL, '2025-10-04 10:17:09.931464', '2025-10-04 10:17:09.931464', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e0694964-7386-4d9b-8e8e-9be601c33a82', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e7012f25e15d8f91ec2e694de4be47c5817b6a092f2f24a56fcc3873361d9390', '2025-10-11 05:33:58.481533', false, NULL, NULL, '2025-10-04 11:03:58.249727', '2025-10-04 11:03:58.249727', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('715ecff8-9e1b-4847-89b5-86a1cd9cceaf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '18fdd4b992b658f4219b5c9030d0b7ed2855c4d211140e91b14af475a539a7d5', '2025-10-11 06:04:57.922296', false, NULL, NULL, '2025-10-04 11:34:57.668614', '2025-10-04 11:34:57.668614', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7614209e-6a99-424a-99f5-28b287c1ae02', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8629530f3ddd297e7f46128ab0469ef4fa7c9e1989b130b0b1eb7f5c2e1645cf', '2025-10-11 06:37:27.886078', false, NULL, NULL, '2025-10-04 12:07:27.634683', '2025-10-04 12:07:27.634683', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('1ac2593c-dadb-48cc-ad20-19fdc5798f26', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '1df1c3c535c8e8ab861ee705ed27856e34a4f0af1add9bdf11943faf7e02681a', '2025-10-11 06:38:08.699336', false, NULL, NULL, '2025-10-04 12:08:08.443057', '2025-10-04 12:08:08.443057', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9e1a163b-cf00-43a4-aff4-92aed169ddfc', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'd11e26664581719ecaa6426a75af5cf1d60bdf6a7a73361ebd8d0f9af92cda73', '2025-10-11 10:47:43.630501', false, NULL, NULL, '2025-10-04 16:17:43.373761', '2025-10-04 16:17:43.373761', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('2ecf7a1a-9113-458a-a29f-263770f7f4fb', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'aadb735ab0d3b44fcea31a5fd4fdf1f5c1a981ce9f2646d090845150c01f4ecd', '2025-10-11 10:50:32.363651', false, NULL, NULL, '2025-10-04 16:20:32.111301', '2025-10-04 16:20:32.111301', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c19a69ea-a544-453f-8b72-1e4555089764', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '9ad24fb4f42131c990a8bf6b63005409744ae143ba9bdf515dd954d4a49a5565', '2025-10-11 11:02:10.923571', false, NULL, NULL, '2025-10-04 16:32:10.668169', '2025-10-04 16:32:10.668169', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('3ac368b1-9287-4aea-9351-9f79a518c915', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '11ad2ba81303d33a0763edf6829460abb77d85b51ef9cc5978d412a3a7767ed4', '2025-10-11 11:05:32.522336', false, NULL, NULL, '2025-10-04 16:35:32.264823', '2025-10-04 16:35:32.264823', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('bc6837ee-5cca-4749-acb4-44989205c219', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '961bdaabbfa4f652ccc757b38c93be7a39fbdf93a9fa4ab743942d69c7d70051', '2025-10-11 11:07:29.367698', false, NULL, NULL, '2025-10-04 16:37:29.114879', '2025-10-04 16:37:29.114879', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('cf088a27-503e-4507-89cd-9640e9bc43ce', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '0d1dd7c1b07be6573b387848d01cd813400665e046672d5ae16f22180eb1eb2e', '2025-10-11 11:09:04.153905', false, 'Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0', '127.0.0.1', '2025-10-04 16:39:03.901648', '2025-10-04 16:39:03.901648', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d97cb2ed-b8c6-47cd-b88b-08a1226d596b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '79d5d54797314e386ea67e111b177a14cb59898de5ad53d691a503e7ff71dee8', '2025-10-11 11:14:54.172892', false, NULL, NULL, '2025-10-04 16:44:53.922584', '2025-10-04 16:44:53.922584', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6faf8de9-1014-4a64-b114-78f5917cb5a4', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'a79577bd38c54d9e704ed1c6c35b1aae65c65d4736d4fa7bfd5b53627de300fb', '2025-10-11 11:18:42.310089', false, NULL, NULL, '2025-10-04 16:48:42.057651', '2025-10-04 16:48:42.057651', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0bde34b4-b460-4b73-bf55-42a31d909a3b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5f51cdc661bf9dfc347c94bd11e00ca70d1337b0271662eab77efa64b569064f', '2025-10-11 11:39:54.079046', false, NULL, NULL, '2025-10-04 17:09:53.821102', '2025-10-04 17:09:53.821102', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ebb48799-2d5b-4e92-b50d-f03345759a48', 'de9dc531-11bf-4481-882a-dc3291580f60', '3dfc2681ee47bb3bcfd024f3c9a004b17f499a7226d0d0ca23edc6f3ba18163f', '2025-10-11 12:07:47.817344', false, NULL, NULL, '2025-10-04 17:37:47.587635', '2025-10-04 17:37:47.587635', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('607bb2bf-2c75-424a-a106-0acea0b9d93d', 'de9dc531-11bf-4481-882a-dc3291580f60', '50ab70a0eea81afbc2d78e54a3cd93382d48ac83681bacb5bea6a4f15b2f6718', '2025-10-11 12:08:14.552392', false, NULL, NULL, '2025-10-04 17:38:14.322328', '2025-10-04 17:38:14.322328', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('734d348e-d857-4570-b498-13c409466aa4', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e2782ad53aa538f885efa719bc92a0caa8893b20c70342be661ab0ddc4c489c3', '2025-10-11 15:43:58.35947', false, NULL, NULL, '2025-10-04 21:13:58.083344', '2025-10-04 21:13:58.083344', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('89544d4d-3ea5-4688-9f37-45a301785926', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'a423bbc78d984f8237afe877f9ec22166dc70c73ca3f39b03ef7fe68c61e887f', '2025-10-11 16:02:11.368306', false, NULL, NULL, '2025-10-04 21:32:11.136223', '2025-10-04 21:32:11.136223', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6d3e2a9d-b8d1-44d0-8689-8a0c76d1a4d5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '52bfa15c3d1b2de8d41c346279f209081960c4ff4163befbf8e8dc56448b6df1', '2025-10-11 16:02:42.406159', false, NULL, NULL, '2025-10-04 21:32:42.174296', '2025-10-04 21:32:42.174296', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('dc704ade-6422-4584-a5c0-a95d21ce34db', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7d107183c3e037a3bba9f487b1a89256ed03a8bf2e4668203092dcdb52e4457b', '2025-10-12 11:37:25.331558', false, NULL, NULL, '2025-10-05 17:07:25.054302', '2025-10-05 17:07:25.054302', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fd779928-7939-4109-a4c3-1d2a8f757781', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6360163edb8feea947898907c88de352e4e5ddea5eadaee9cf7099b095a95290', '2025-10-12 13:14:43.221757', false, NULL, NULL, '2025-10-05 18:44:42.967604', '2025-10-05 18:44:42.967604', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('cd5f1a8e-ef41-44bc-ac2d-6ec13076a798', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '498f43dde21386b333c72193cdf253fd1fa44096bb18580ee00b8a3d45af6760', '2025-10-12 14:16:46.067284', false, NULL, NULL, '2025-10-05 19:46:45.815118', '2025-10-05 19:46:45.815118', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7714d626-933f-4ffd-bfa3-588dd4ba52c1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '79c3bc1e37f8de17e3b1a5d4e6cb438dc85965762bc2860a63ad20d069f6ea77', '2025-10-13 11:56:08.344817', false, NULL, NULL, '2025-10-06 17:26:08.071072', '2025-10-06 17:26:08.071072', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c0a6b652-c178-48ec-bbb2-da1639bbc81c', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e5b57be966eff7b1955002f395f10f5fef82177f3b4f7421869d681c2c49dc5b', '2025-10-13 12:15:24.47691', false, NULL, NULL, '2025-10-06 17:45:24.215526', '2025-10-06 17:45:24.215526', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('17dd0e95-4d5e-4b11-989f-28933814e71f', 'de9dc531-11bf-4481-882a-dc3291580f60', 'faa3e21c0cbdc448b0a883fd0a92e822ebe3a29d06563c9cbefb095828307d8c', '2025-10-13 12:16:16.840209', false, NULL, NULL, '2025-10-06 17:46:16.60849', '2025-10-06 17:46:16.60849', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('71322e6b-f2ec-4640-8136-a4990be090ab', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '19a1a916183f5403fff2d126111cb431e75ce7ac036324aeda7b406d157fa056', '2025-10-13 14:59:23.625917', false, NULL, NULL, '2025-10-06 20:29:23.351663', '2025-10-06 20:29:23.351663', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('73f736be-e377-4aae-85de-3dc36ac6b359', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8d3bb4d1c8bbf9c2652a16321f52836ca94a593804cdd1e11765d6b82b856455', '2025-10-13 15:03:30.388229', false, NULL, NULL, '2025-10-06 20:33:30.157421', '2025-10-06 20:33:30.157421', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('baa7e6da-be0b-40e5-a05e-d90b30539525', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8d7e2555e4d55444ad575df5e07e469d2005793fab97c5ee1bb50bda7cf2f21d', '2025-10-16 04:52:48.925756', false, NULL, NULL, '2025-10-09 10:22:48.635057', '2025-10-09 10:22:48.635057', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('1aa24574-30fa-42d2-a895-fccce1c5b99d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '31c17c42176993e22644d46b364195e755b296e35bf82bf3f0f1ca61679a9d5a', '2025-10-16 05:22:45.09409', false, NULL, NULL, '2025-10-09 10:52:44.790191', '2025-10-09 10:52:44.790191', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fa014559-86ed-443b-8b12-5c05d98cf83b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'abecf13aa0ca2b156d7fd44caf42cc0aaf029888bf7e12e71d45c1a5dee61359', '2025-10-20 22:02:08.166285', false, NULL, NULL, '2025-10-14 03:32:07.913195', '2025-10-14 03:32:07.913195', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('dea5bdd8-4d8c-48bb-94fc-5a19265b9ce3', 'de9dc531-11bf-4481-882a-dc3291580f60', '3f8755bdc5a7045e1468c140c5dd55357aa6b3f988955c3d4889363f0aa0567a', '2025-10-21 03:06:32.879256', false, NULL, NULL, '2025-10-14 08:36:32.583695', '2025-10-14 08:36:32.583695', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('3c34c1a5-9974-43f2-a343-b45eb492afbd', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7ccea9841857de49c3a64b273cae4c3ec423cb8e59910488585ca51a127568e4', '2025-10-21 05:51:28.458687', false, NULL, NULL, '2025-10-14 11:21:28.203614', '2025-10-14 11:21:28.203614', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('31b419c7-9f92-4dd4-b308-75d2929f4592', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5b90203b73845983ad0497e27fa345a5410e243f9772aa453a46b62f901923db', '2025-10-21 06:02:38.887519', false, NULL, NULL, '2025-10-14 11:32:38.636264', '2025-10-14 11:32:38.636264', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c6c7ce8f-f5f8-4cf1-9166-afc800ffd218', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'daaebdd6b7c483d346002137f349ca5f6fd37d4a94f2d5c388f9736a7142ca07', '2025-10-21 06:44:15.06355', false, NULL, NULL, '2025-10-14 12:14:14.813036', '2025-10-14 12:14:14.813036', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('523dbc8b-12b3-4370-ae93-532bcfda7810', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '56b10536dce6eab47a26fc71f9e057e8d8ac47bd227bcf7cfa4d707ae3fc605f', '2025-10-21 07:12:18.776174', false, NULL, NULL, '2025-10-14 12:42:18.52639', '2025-10-14 12:42:18.52639', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a5a0814e-1586-46fe-b6bd-61b638af524d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '441a42404a0059bcf3a6c9e2831b626e02c7b16334fcff33c37acf0594cc9a2a', '2025-10-21 07:44:40.406085', false, NULL, NULL, '2025-10-14 13:14:40.146035', '2025-10-14 13:14:40.146035', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e980e828-182e-454c-8a78-26e819f09af8', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2cdaf4dbe0869f7a5ebcdd8dce8602dfd500a34563f484ef01d6caf10efdb3d1', '2025-10-21 09:59:30.632381', false, NULL, NULL, '2025-10-14 15:29:30.401395', '2025-10-14 15:29:30.401395', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('92d41c9f-8c35-4f44-8f21-230ab46d6db6', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '595c6b21e26fe8fcad2b8a43956208ccd72b3844756ee67b8d4a778d60feccc8', '2025-10-21 10:11:26.07421', false, NULL, NULL, '2025-10-14 15:41:25.839049', '2025-10-14 15:41:25.839049', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('19fda176-3af6-432c-ae08-ae8930842884', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '64db491fb6fb3fbd515bfdf29ec9b2d3e93bb974e98472d81840ff653e882a35', '2025-10-21 10:14:15.337591', false, NULL, NULL, '2025-10-14 15:44:15.101537', '2025-10-14 15:44:15.101537', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('43f44f26-f677-476a-ae31-eb9b668e7d72', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'de44e639e839d07bfcd29777224b28738adbf1d674bc3537dd803a45ecb3bc24', '2025-10-21 11:04:13.629428', false, NULL, NULL, '2025-10-14 16:34:13.375924', '2025-10-14 16:34:13.375924', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4480e879-3281-4c77-8d54-ea5aa6a39ece', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '0d06c31b33ec4ff28da75bc7c48edf3251990749444caa67335daeecfa882f5c', '2025-10-21 14:49:34.365341', false, NULL, NULL, '2025-10-14 20:19:34.110702', '2025-10-14 20:19:34.110702', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('15c44ca0-255a-49c0-91e4-dac09856ff00', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'df5c9a53bf2a402ec7db44c2dce95ec09db1ebff4434f9c2763c44280e3388a5', '2025-10-21 14:53:48.77464', false, NULL, NULL, '2025-10-14 20:23:48.542225', '2025-10-14 20:23:48.542225', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('18ec17a3-01f8-4166-a5d7-a3c248487403', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c23ece18dbf266ca3a0439fbc0a8bbf7a96248d4961f4f6ba820f8785876ed89', '2025-10-21 15:10:43.35045', false, NULL, NULL, '2025-10-14 20:40:43.097626', '2025-10-14 20:40:43.097626', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('1324afc4-0705-4f55-bac3-a8762b02c0e3', 'de9dc531-11bf-4481-882a-dc3291580f60', '28c9902e6a8d8a674ea8e8cd939e3bed483a793c6b58ce0bcc6ec28d713a9f76', '2025-10-21 19:58:36.598473', false, NULL, NULL, '2025-10-15 01:28:36.338553', '2025-10-15 01:28:36.338553', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('61a2317e-cc0c-41e3-80a6-6265ce9b605f', 'de9dc531-11bf-4481-882a-dc3291580f60', '87da8aa69bc137da0696b8cc4e3aa52f89ee7af9d67a62a47dc17dd9add1e804', '2025-10-21 19:58:36.841628', false, NULL, NULL, '2025-10-15 01:28:36.610599', '2025-10-15 01:28:36.610599', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('33f9f2c6-d6a8-44b6-ac8c-36af49b5be12', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '185e8c5816eef3b35107d587e59a5f72680267bca514f9aa879c93aa0efe3503', '2025-10-21 20:16:34.922366', false, NULL, NULL, '2025-10-15 01:46:34.671403', '2025-10-15 01:46:34.671403', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('1005b897-544f-4f31-92b6-651b41117e19', 'de9dc531-11bf-4481-882a-dc3291580f60', '8a71f29c4916545d183d93224422b0ba8b357669942d7ab5c8f87e9b17bd18f3', '2025-10-21 20:39:56.803098', false, NULL, NULL, '2025-10-15 02:09:56.551707', '2025-10-15 02:09:56.551707', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('b917e95e-5073-419c-a62d-c1661cd23435', 'de9dc531-11bf-4481-882a-dc3291580f60', 'eaf9fa7b7e3a953442ebb3f37c58f71ec84ae294e726f0e494fab49fcebdefeb', '2025-10-21 21:11:46.825187', false, NULL, NULL, '2025-10-15 02:41:46.594936', '2025-10-15 02:41:46.594936', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('324524bf-90cb-4126-8d7c-413d1cc4e508', 'de9dc531-11bf-4481-882a-dc3291580f60', 'b95fc34b767b79813029789e514db6534caae9fe7dc3acb27122a892cfdaaf86', '2025-10-21 21:50:37.191754', false, NULL, NULL, '2025-10-15 03:20:36.892423', '2025-10-15 03:20:36.892423', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('03602ca9-a1b1-4d5a-8adc-3d7b9672710e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '98eb17bd2cd02061bdaef0481267501f40f9d34e9e560948c2ef9f28c744e961', '2025-10-21 21:50:49.286991', false, NULL, NULL, '2025-10-15 03:20:49.057488', '2025-10-15 03:20:49.057488', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('58e8340f-1a57-462c-bece-6fedade563df', 'de9dc531-11bf-4481-882a-dc3291580f60', '03f5c77f3ddddbb0ce675ec3541f27a86beb40bb4051fd4b72e598badd6feca6', '2025-10-22 03:50:14.451511', false, NULL, NULL, '2025-10-15 09:20:14.196345', '2025-10-15 09:20:14.196345', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('145baaa9-56ce-4710-91af-eaf81cddfca4', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3ca158aec560eb1875ddbf494c3de4bf2d9645362c7c365686972f4e60f25c4c', '2025-10-22 03:51:39.746575', false, NULL, NULL, '2025-10-15 09:21:39.516151', '2025-10-15 09:21:39.516151', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('00e9afc6-a628-4753-bf1e-fc565f357a2a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'b9681c960ee35411feccb9d4fd31f07b188ce64c55436572f7ba26b9591d747e', '2025-10-22 05:07:26.835732', false, NULL, NULL, '2025-10-15 10:37:26.572556', '2025-10-15 10:37:26.572556', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('94636109-1245-4efc-8fbc-e28964e24323', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'f541c01f41115ea61f050dc23b11236b110d92d9987c4c4540ac1f3735444bae', '2025-10-22 06:05:55.231185', false, NULL, NULL, '2025-10-15 11:35:54.969921', '2025-10-15 11:35:54.969921', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4265a596-09e1-4bdc-8941-2d155d6cbf06', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'bdf32ff9f9a84a3849f2c98ec5a90f531565640643eafca01e5a919ab120654a', '2025-10-22 06:07:33.800476', false, NULL, NULL, '2025-10-15 11:37:33.569428', '2025-10-15 11:37:33.569428', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('cd3f7e20-6c9e-4428-8a5f-5cec32f4d68b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '031b87425bab569abf61b5e80c64870e38bef053df6cfe3b6135677b5dfef345', '2025-10-22 07:05:35.098532', false, NULL, NULL, '2025-10-15 12:35:34.83962', '2025-10-15 12:35:34.83962', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a3b7524f-2514-42e9-be19-1fb532dbeb29', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7ca8a5dedcb6f89254146ab8ea0909531f8e746942ffb6fcd653fe732351161c', '2025-10-22 07:24:27.554781', false, NULL, NULL, '2025-10-15 12:54:27.128229', '2025-10-15 12:54:27.128229', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d2bb83e1-da09-47c3-9c3f-fd3e868528ed', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'd64f8cbc96e926ba25863844460e62155b7ecc27c2c2056826500c9615f0cf26', '2025-10-22 08:03:44.346681', false, NULL, NULL, '2025-10-15 13:33:43.872412', '2025-10-15 13:33:43.872412', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ee94ddae-2b3c-4476-afb9-54bce0d8c0bf', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '9150bac21990bd9eda44a2d9675ddb7f26fe641d6da7bdcd41304daec3d116bf', '2025-10-22 08:35:27.371347', false, NULL, NULL, '2025-10-15 14:05:27.088298', '2025-10-15 14:05:27.088298', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ec39a433-79f1-4da6-ac5f-1562b9ee37ca', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7241eb63a9163b064dcbe1e3043449b6d676c7a606123333889fa80a38741471', '2025-10-22 15:33:42.454019', false, NULL, NULL, '2025-10-15 21:03:42.199892', '2025-10-15 21:03:42.199892', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('519d611f-32c5-4e27-9b62-cc223abc6c66', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4bf9237e1c579323c312ce2c07df63ff9441742b3990a0c70ed05953782e7fed', '2025-10-22 15:59:38.681339', false, NULL, NULL, '2025-10-15 21:29:38.451423', '2025-10-15 21:29:38.451423', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ae4962ea-5ce5-4cc4-9d8a-51aa16a54e2a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '35a66ec00dce12d61f6d90728574506ca068daf36323b3e7f94d96cf7d64b600', '2025-10-22 17:09:10.53833', false, NULL, NULL, '2025-10-15 22:39:10.262594', '2025-10-15 22:39:10.262594', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0c984c71-d9eb-4cd0-b5c2-099e70fdd32f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'dc3b7487325950fb2b8e8981223b225810443ae1f35e23e71817a4d07a5296c2', '2025-10-22 17:25:20.887494', false, NULL, NULL, '2025-10-15 22:55:20.604118', '2025-10-15 22:55:20.604118', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9e58363e-71de-496a-a7f0-39e857dbbe75', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '0c40b73aebf3138c906ecbf01d8152ee24c193e6b7ab2e762e5a1b2d3940c441', '2025-10-22 17:39:37.903786', false, NULL, NULL, '2025-10-15 23:09:37.652362', '2025-10-15 23:09:37.652362', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('07d7bce3-d205-43da-a7ca-c937dbce20f6', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'bdcb558dc25d0b40da27a201219da99dba5ab53e8900586495836a03ea04d2f4', '2025-10-22 19:28:15.820721', false, NULL, NULL, '2025-10-16 00:58:15.554004', '2025-10-16 00:58:15.554004', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('945e1106-20fc-4197-bd2b-2d33520b2780', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c7ab7720b905d23f53d106c31a7ed925855bf7c74219793e4e558498d26aafe1', '2025-10-22 19:38:53.206462', false, NULL, NULL, '2025-10-16 01:08:52.976485', '2025-10-16 01:08:52.976485', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ce440ab3-2940-4d3e-9418-7cde88775475', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8e9ea5792a80c178110fdde3d343e7fc87da2501581584d8541a809197f1ebe8', '2025-10-22 19:52:26.56713', false, NULL, NULL, '2025-10-16 01:22:26.334624', '2025-10-16 01:22:26.334624', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9dc00daa-2b6a-40c6-b33f-2b62605b4c20', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '384eb55267168ed05b6b22c1dbcc8451a0f54fa11cf191d7328e4291fba6ad07', '2025-10-22 19:53:38.745138', false, NULL, NULL, '2025-10-16 01:23:38.509223', '2025-10-16 01:23:38.509223', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('debe54ca-4741-4717-b274-10bb59317613', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '55f4656eb47700b1236b87698f2357910bd25ebd235804cfc20e3d34618ade1a', '2025-10-22 20:06:04.166428', false, NULL, NULL, '2025-10-16 01:36:03.896813', '2025-10-16 01:36:03.896813', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6b4e9e27-6fe7-408e-8af0-4ed75141eec7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'f2feeb6c2a72e91796a9421b9727f154d1f5cf6bf2850ea0ba2e2d196483cd23', '2025-10-22 21:44:24.63096', false, NULL, NULL, '2025-10-16 03:14:24.377375', '2025-10-16 03:14:24.377375', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('249d7ea6-448b-44f8-b324-3adf9c41edde', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '184d5566571495986959f95b8e6f2fc4bcb1c29e45dfbd55c29fe3fe2c228be8', '2025-10-22 21:48:09.065503', false, NULL, NULL, '2025-10-16 03:18:08.814083', '2025-10-16 03:18:08.814083', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('43e5f9fa-29ec-4839-bebf-49037968b136', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e201a30954f5e2ee9e57eddf6af172f4f901c96edc24c000254ee227a74f8642', '2025-10-23 02:59:20.923851', false, NULL, NULL, '2025-10-16 08:29:20.670469', '2025-10-16 08:29:20.670469', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4f4e3be3-91ce-42c6-90ec-e675d597e25f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6fbc2753c957c1ef23cb02414f964f6098ea437f9fdc9ae2a7bbcb651bb67d5d', '2025-10-23 20:01:34.298905', false, NULL, NULL, '2025-10-17 01:31:34.036194', '2025-10-17 01:31:34.036194', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('97e579a6-f7a3-49a6-8d12-b10efdd4a9ac', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '038c2889be3100f640e057bb58e3f12454ff6444257d3c5b78ddba241807f2e3', '2025-10-23 20:12:33.528534', false, NULL, NULL, '2025-10-17 01:42:33.29793', '2025-10-17 01:42:33.29793', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6160dd60-6007-44bd-8bd9-099595964271', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '0e21a20d6e1afb652b20471a0adeda0d2890efc57b035925af9f43e134ed1062', '2025-10-23 20:49:30.909983', false, NULL, NULL, '2025-10-17 02:19:30.656344', '2025-10-17 02:19:30.656344', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5243de42-916e-4038-b724-9d7252939bef', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '84f9ecc037f86194ecd319c88d144dc79502c19ef98cdeff4241d06d2725dff6', '2025-10-24 04:13:32.51086', false, NULL, NULL, '2025-10-17 09:43:32.220607', '2025-10-17 09:43:32.220607', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('efd662ca-82e5-43c9-a1a2-dddb28fe1026', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4abc787e1e6304236656010a140d1c0f8b317a775e31cc7d93e568e2ec1097b9', '2025-10-24 04:38:16.963188', false, NULL, NULL, '2025-10-17 10:08:16.469058', '2025-10-17 10:08:16.469058', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('bfe59c5e-ee1c-4e56-bc4b-049ccbbdf30a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4ad0dc8e9ea1d2158bc7e7f3d80b2335beafd138b28332345880178e080fee4d', '2025-10-24 06:28:46.276527', false, NULL, NULL, '2025-10-17 11:58:46.014058', '2025-10-17 11:58:46.014058', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('dfb27feb-f78e-4882-9f38-a4646a0eddd2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3ec056f561cfe8edbab13c4c650f7cd57a0348cc33efcf0fbb14504089a0cb00', '2025-10-24 08:05:23.384503', false, NULL, NULL, '2025-10-17 13:35:23.135245', '2025-10-17 13:35:23.135245', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c055f6c7-afc4-4fbf-8732-39580166688f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'fbe103f78bb734387f4fe88e40afe09a709344712fa4a1fcce472fa41c42b34d', '2025-10-24 09:41:10.33303', false, NULL, NULL, '2025-10-17 15:11:10.064904', '2025-10-17 15:11:10.064904', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('887fd0d6-7a66-40b0-b8fd-c4e015e62a8c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7e926ff1687fd085b4452196be7a407c5cd6012d26e21ac4000e011065a57a42', '2025-10-24 11:59:54.612581', false, NULL, NULL, '2025-10-17 17:29:54.360046', '2025-10-17 17:29:54.360046', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('eb498d45-2c8b-4cbd-b270-1345da9a504c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'ef488ed693e9e3ae32f053c4f7b2dfaf54fcc36a49d7496b03610ceca46adc3b', '2025-10-24 14:03:50.347535', false, NULL, NULL, '2025-10-17 19:33:50.096151', '2025-10-17 19:33:50.096151', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d194b018-aa71-4b00-88fe-9b625a22f059', 'de9dc531-11bf-4481-882a-dc3291580f60', 'f2fffb88f00d7b9d84864b55b8fc7d2a3c844056f5cf981eeb15ab1bb95ab1eb', '2025-10-24 15:57:47.134815', false, NULL, NULL, '2025-10-17 21:27:46.891366', '2025-10-17 21:27:46.891366', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e63c05af-17b1-408c-85c6-127615d67e9e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c2d205f5a0d3eb57ac51d66bff4e0500d7a87a3a4cb2c13b0ca83beb8f68eb7c', '2025-10-24 17:06:21.855485', false, NULL, NULL, '2025-10-17 22:36:21.601584', '2025-10-17 22:36:21.601584', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('aefc7731-7c31-4076-aded-5e7b0d992a2c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '7015a4c212c983c76f704714cb6fe5867448b1e09e2a933eea3183c5f128a0ca', '2025-10-24 18:00:54.445559', false, NULL, NULL, '2025-10-17 23:30:54.167469', '2025-10-17 23:30:54.167469', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c080a3e0-301f-46fc-ae1b-045781758a0e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8622de75cf06c24f65f394a18cc2a4e3f1d478b4f21fb8ae7ad821b2a21f760a', '2025-10-24 19:50:00.572301', false, NULL, NULL, '2025-10-18 01:20:00.291558', '2025-10-18 01:20:00.291558', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c058f991-726d-4882-99c9-091c33e13f17', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '277e91143e7b476685ee58c41b1502cf730819f2635debeb94e0cf2705a9d0f1', '2025-10-25 02:10:52.228605', false, NULL, NULL, '2025-10-18 07:40:51.97495', '2025-10-18 07:40:51.97495', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('23281960-f17a-40e3-9029-8f5dd95d4a03', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'a5a7eccd813a2d11c41dce2ff8781e1105b1dee1a4219b3888bf6222ff6ba168', '2025-10-25 02:15:51.971159', false, NULL, NULL, '2025-10-18 07:45:51.722287', '2025-10-18 07:45:51.722287', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e9763711-c3cc-4a19-9155-8b28a251b283', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3c5b82de65a0773fdc19f4c14c6471ca3d481f7c76ce000d574b69c324cc2cd8', '2025-10-26 19:12:32.521592', false, NULL, NULL, '2025-10-20 00:42:32.266733', '2025-10-20 00:42:32.266733', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('dfc402f3-23f5-4f71-a80f-8baf3b6d7ac3', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'eb1a87076e5908ffd701ead187590c75ab0696ebda1602718ed264321009cad2', '2025-10-26 19:38:06.53979', false, NULL, NULL, '2025-10-20 01:08:06.28421', '2025-10-20 01:08:06.28421', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5bd6ecf8-cfde-4772-a7d7-c5002071b906', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'df8a14c4b8059e64a67398c4b3b3f63701817c0741c0a294805db7e79ff52aa9', '2025-10-26 21:06:16.780274', false, NULL, NULL, '2025-10-20 02:36:16.547568', '2025-10-20 02:36:16.547568', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e6bf809d-1cf1-4f95-838c-a17bd62028fe', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '56c0193582cf29a5184b19c796fd5c1ee0ccd20c55c6d40a5fea44a8d936b662', '2025-10-27 03:33:48.792877', false, NULL, NULL, '2025-10-20 09:03:48.536193', '2025-10-20 09:03:48.536193', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('652750b9-b15c-47dd-9b72-566480e7d35d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'cdd2be1b17e109e148b4136dbdabbd1e04cd85ece7965d2faa6066c89b7aa403', '2025-10-27 03:39:01.568083', false, NULL, NULL, '2025-10-20 09:09:01.291779', '2025-10-20 09:09:01.291779', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('16156f12-1c14-480f-afa7-f77c63e64d2b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'dbdcf85bd076448673aeca44ae66342d91effda7bc7d305b45916393f2ba38b9', '2025-10-27 07:28:42.668029', false, NULL, NULL, '2025-10-20 12:58:42.38307', '2025-10-20 12:58:42.38307', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('378794ae-7d10-4de3-822f-b54a59fbf76e', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '153e3b60f528bdad08a159820347f452d9423ba905394c4c40d61ea5fa1edb2c', '2025-10-27 07:49:15.347339', false, NULL, NULL, '2025-10-20 13:19:15.094805', '2025-10-20 13:19:15.094805', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('214b954d-7073-4b1f-b991-052cf933dbe4', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'dde4b919bc35074cf7ddf80bdb625e928644bf1cc8cd7df051627ca09382c10a', '2025-10-27 08:40:32.141125', false, NULL, NULL, '2025-10-20 14:10:31.890143', '2025-10-20 14:10:31.890143', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('db31f6bd-13f6-4420-b544-0d03e6cf7260', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3515a7beb3e5b71a381de68f135924ff46ba559c611fc2794ed76bb6913a5988', '2025-10-27 10:38:42.472349', false, NULL, NULL, '2025-10-20 16:08:42.220467', '2025-10-20 16:08:42.220467', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('38ef7172-a6d2-41c4-96fc-14046df61490', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'adfaece0d2640b736f615e3f1c4192f7622f09c22177f9b4d84b171a086b69f2', '2025-10-27 11:35:17.136004', false, NULL, NULL, '2025-10-20 17:05:16.883192', '2025-10-20 17:05:16.883192', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('bbc0b4f8-08d1-4824-a5db-9912049560d7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '27a3f3e409bc82065c13ab3e332fd02805f0b53b2a0a178b8e617c223b4cf0d7', '2025-10-27 12:15:42.666926', false, NULL, NULL, '2025-10-20 17:45:42.376865', '2025-10-20 17:45:42.376865', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('77f0f085-1e04-4193-8a03-53326e971738', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4b5bc33ef7f4ae73e780b4c28b27db91266629e2b5dcaeb841838fe2c7d04770', '2025-10-27 12:23:41.917268', false, NULL, NULL, '2025-10-20 17:53:41.661569', '2025-10-20 17:53:41.661569', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('107cb266-c540-49fb-9c76-9f7ea9fc02a2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c583ffc229f70490451d87fd03e9e68bcf300bd92024ca4b5430f5c3ea7762f4', '2025-10-27 16:26:52.34562', false, NULL, NULL, '2025-10-20 21:56:52.087239', '2025-10-20 21:56:52.087239', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('8b9422f8-4fbd-4a51-87fe-635cd3cf0f95', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '0a21f89af7485cd44ef2cdb49e46b8851d4951d4af30bea7f4adb596a4b7a97a', '2025-10-28 01:01:01.970025', false, NULL, NULL, '2025-10-21 06:31:01.702834', '2025-10-21 06:31:01.702834', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('468f8687-52e4-4d7c-863d-7146729d7cd9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c9db31a2ed009ceae966a84261135158ddbc7927a04908b56151b40775c99b99', '2025-10-28 04:08:14.108006', false, NULL, NULL, '2025-10-21 09:38:13.856585', '2025-10-21 09:38:13.856585', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('36a961e1-d593-482c-a460-b72e18b24499', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e6eb2b01fdcdf0cca3f28c6228827d1a01192f0b556b0bf772a30d7cd6b5ddce', '2025-10-28 04:12:02.53894', false, NULL, NULL, '2025-10-21 09:42:02.307944', '2025-10-21 09:42:02.307944', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('93379c25-70d5-4e0b-a3a1-fa543fe49161', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '9b1ca017dc2a1436bc32b7c2ed09453c04ad7dca53abae9e75491e94a45d860f', '2025-10-28 04:14:41.875817', false, NULL, NULL, '2025-10-21 09:44:41.643947', '2025-10-21 09:44:41.643947', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f1a1b473-edf2-481d-b60a-8f2acc4648d4', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '803017d38fc2bc183f87631afbfa8b8d9569824510f7b8908e3efe3a849a293f', '2025-10-28 06:23:07.098739', false, NULL, NULL, '2025-10-21 11:53:06.846103', '2025-10-21 11:53:06.846103', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9343a2c9-d024-44e1-857f-68e819ae1759', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c06d5fb802e1d05cd881b7fc7f084708b2aace8838da56153f9e45124c190a15', '2025-10-28 09:04:23.941846', false, NULL, NULL, '2025-10-21 14:34:23.689212', '2025-10-21 14:34:23.689212', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0d2f3443-fe79-4225-8cde-dc10654003f5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '54748662cca592052f872a3eba57c228f415c7f596debc12a820694fa71f57c3', '2025-10-28 12:43:11.475017', false, NULL, NULL, '2025-10-21 18:13:11.21916', '2025-10-21 18:13:11.21916', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5bbbce15-56cc-40ba-9360-21619349500c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2e7a38ff8a4da834d78b817791df56a9912fe15bf1fef1739de2615fc2d8d949', '2025-10-29 05:05:58.908064', false, NULL, NULL, '2025-10-22 10:35:58.605039', '2025-10-22 10:35:58.605039', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('84043a77-3485-4987-b3b6-a23c1d2ae13c', 'de9dc531-11bf-4481-882a-dc3291580f60', '159505c19737de845aeb9e280a26d8ed959ad0ef74d99aca6df53f17969298de', '2025-10-29 06:18:28.575071', false, NULL, NULL, '2025-10-22 11:48:28.31118', '2025-10-22 11:48:28.31118', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c0a7d73d-d99f-4b04-b888-cfb63e510fba', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'a72133ffa0939fb81ef7f383234ef847fad65fe064a8a71f5cc08e02a7fde6da', '2025-10-29 17:20:19.381478', false, NULL, NULL, '2025-10-22 22:50:19.10262', '2025-10-22 22:50:19.10262', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('481c329c-b33f-4818-8cb4-8b5008914e02', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'cd19b7c39873ef66f8cc91dd85b7cf6566007f50b4c8a104cfdf4a293f9a2cd8', '2025-10-29 17:31:18.715543', false, NULL, NULL, '2025-10-22 23:01:18.462606', '2025-10-22 23:01:18.462606', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7b67e723-2088-457c-973c-e36e941783a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4e5e0ad4a92762df3e1d7aff508cbd8ceaae76941082981cabcd1cee27b2603f', '2025-10-29 17:31:39.220678', false, NULL, NULL, '2025-10-22 23:01:38.970384', '2025-10-22 23:01:38.970384', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f9bf6402-3ada-4a6e-ad41-dae8d049b71a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '4eb631ef33d4ae7bb33884e5eebc792a11dfea6de73ccaba1aee9b0f6a5a456e', '2025-10-29 17:32:23.720033', false, NULL, NULL, '2025-10-22 23:02:23.466453', '2025-10-22 23:02:23.466453', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4a36a18b-3673-4deb-bea2-dd6d0518bb24', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6f15efa1b5235ff27cd5cd0fc0764487b5991be78690c0e4cd419e19cefad52f', '2025-10-10 04:34:43.706148', false, NULL, NULL, '2025-10-03 10:04:43.475429', '2025-10-03 10:04:43.475429', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('b558b7e1-ae7e-4064-90bc-4b9f2d06045d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'c946b964ae42f5eeefba0fdc56b74d5fcbb556d2d28de4a14aa16ea00783aa8c', '2025-10-10 04:34:55.129447', false, NULL, NULL, '2025-10-03 10:04:54.898649', '2025-10-03 10:04:54.898649', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9b6edbd1-5e51-4234-8eb1-9103b33b558c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'b6f75955be7b0a77aa87b65a243129dbc702916ba4c259ab683f01aa71f761b3', '2025-10-10 04:38:22.870659', false, NULL, NULL, '2025-10-03 10:08:22.620706', '2025-10-03 10:08:22.620706', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('490762a3-a17a-463a-a895-14fed7ce4bc7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '1d3cab6b3c14201788df21911669f243f3a16321c7865afd840b9569a6dba04e', '2025-10-10 04:38:23.496787', false, NULL, NULL, '2025-10-03 10:08:23.266839', '2025-10-03 10:08:23.266839', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('55483c86-a0f8-445f-8fe1-a58dffe13f06', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e25ebf4795697ad936c510ae24f5f100fdb84b98aaae220684c78e104101c72f', '2025-10-10 04:38:41.395095', false, NULL, NULL, '2025-10-03 10:08:41.141849', '2025-10-03 10:08:41.141849', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('8623a8e0-a916-4da7-91b0-674168fb09b9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '49abe4773b3b3b0ea8f5e715b37781f38428df35824416975dbb71c9a5ac5e0e', '2025-10-10 04:39:10.962592', false, NULL, NULL, '2025-10-03 10:09:10.690177', '2025-10-03 10:09:10.690177', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('76605ce2-1fa7-4557-9f64-a3c365d003b0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'f94099c6333cd79ee142b561cbfda1431f211aaf6c877fa1365b2f3ce037b188', '2025-10-10 04:40:11.146656', false, NULL, NULL, '2025-10-03 10:10:10.896385', '2025-10-03 10:10:10.896385', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('77b62f6b-5874-4b66-a8fd-73ab3b6cb2f1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '22e5545eaa210cdb8f8325a356b35da8fbb77a10a6a7d3f8b98cfc66701a5723', '2025-10-10 04:40:55.505138', false, NULL, NULL, '2025-10-03 10:10:55.258937', '2025-10-03 10:10:55.258937', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c15608e7-c0af-4b25-987f-c2be533e6ffa', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2f4aa6b796b327c3608ba69d329be78b1cf4b292d11cc6aa831431145bd1d649', '2025-10-10 04:41:21.548474', false, NULL, NULL, '2025-10-03 10:11:21.303025', '2025-10-03 10:11:21.303025', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ae88f4cb-13da-4998-8005-19b24c9954ad', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'b684259f5642ded5e4ed5f36649a071cccd85ac32692ab68ded48ab0224db618', '2025-10-10 04:41:37.130593', false, NULL, NULL, '2025-10-03 10:11:36.890656', '2025-10-03 10:11:36.890656', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e45af60a-79d5-4b8d-bf7f-6782dfc457b7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5dafb2fe31340e1cbd295e3781dabd15b2f5a81323d41d0582be809541bae29b', '2025-08-11 05:01:28.164227', false, NULL, NULL, '2025-08-04 10:31:27.928611', '2025-08-04 10:31:27.928611', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0231366f-5856-4958-b8a8-3f44115b605d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6c80890317331c410cbb1d0b02cf3c1b8955b50cbb3144e940343ecc486886e0', '2025-08-11 05:02:39.378973', false, NULL, NULL, '2025-08-04 10:32:39.147603', '2025-08-04 10:32:39.147603', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e5015fa8-5184-434f-ab13-b8dd26df8ff1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '92693f457adc6762ae8c755546f6feddbbb231332f34736aba5bcf98e2a583c7', '2025-08-11 05:03:34.204989', false, NULL, NULL, '2025-08-04 10:33:33.959705', '2025-08-04 10:33:33.959705', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5b5a218e-738c-4ae8-ae3d-0de9457263c2', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '420417c99e5ac9aaae8a512bbc0f9b448999e588f349a820a24568056ae61d98', '2025-08-11 05:04:37.855027', false, NULL, NULL, '2025-08-04 10:34:37.618426', '2025-08-04 10:34:37.618426', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c50cb721-b584-47e0-9629-41f8cc06be6d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'f28d1c424bfd19ff62fdc9ba1a104295611f229f6b6eeba363eb5e2fada5ac49', '2025-08-11 05:05:29.139894', false, NULL, NULL, '2025-08-04 10:35:28.909602', '2025-08-04 10:35:28.909602', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('23c8b466-819a-499b-981b-92081345e00a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5f2144d65fbe3da642b4d4c9a2f2069d22ddc3318f4953babb648fc675a3f51f', '2025-08-11 05:05:41.939884', false, NULL, NULL, '2025-08-04 10:35:41.710177', '2025-08-04 10:35:41.710177', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9f34e52a-2372-4d43-9aed-5aba24752ff5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '0a8cc511daf4ef49e3c12c1c88c5bdd0be8d8dad6dab119f28c902d0b7ce14af', '2025-08-11 05:06:26.068765', false, NULL, NULL, '2025-08-04 10:36:25.802419', '2025-08-04 10:36:25.802419', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('8f63e5a5-7f56-46ac-be72-7c3d6896916f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '321f85259f80a82b686ac17c7147f2d64b6ed314ddc4f55fc2b2808edbf029be', '2025-08-11 05:06:40.000966', false, NULL, NULL, '2025-08-04 10:36:39.771612', '2025-08-04 10:36:39.771612', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('73c58ad7-bdf3-4abc-ab4f-5a97adfc4087', 'de9dc531-11bf-4481-882a-dc3291580f60', 'b41d9dba50eef6b2b88ace77aa405c74640e4d79ca81b02529e45ee97906dd6d', '2025-08-11 05:06:50.963842', false, NULL, NULL, '2025-08-04 10:36:50.713791', '2025-08-04 10:36:50.713791', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('2cfc976c-9201-4446-b45c-936044f6835a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2285ab58514b0c14354d9c17cd5b157a191a4228b3926c0d11019f2ecf23a593', '2025-08-11 05:07:25.872488', false, NULL, NULL, '2025-08-04 10:37:25.621172', '2025-08-04 10:37:25.621172', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('aea78b5e-51d6-4315-a157-918ea96d7a93', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '655c6f10b74eeee69f4c88ebf683243fc9d01f77ef3f911cf79f1dd8c2642797', '2025-08-11 05:07:40.647654', false, NULL, NULL, '2025-08-04 10:37:40.396056', '2025-08-04 10:37:40.396056', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ab04c8fb-8ac2-483c-b9bc-51a66f28ff86', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '26f77541d0719738af2fc68a0e4bf42f92f0ef416f5f42636830982ba6b55506', '2025-08-11 05:08:19.11164', false, NULL, NULL, '2025-08-04 10:38:18.882222', '2025-08-04 10:38:18.882222', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f144c757-ee26-463a-ab6c-5eef8d358dd9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '87afed135780f0a3b6c0b99e6d8cee8f191a62fa18559208b1e3394df1cbfb53', '2025-08-11 05:08:34.189306', false, NULL, NULL, '2025-08-04 10:38:33.959442', '2025-08-04 10:38:33.959442', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ca274675-bb8d-489d-b4a4-cdc5fe49a3ab', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '50f6fce060ec9bd7e09a6eda0b236eaa562d6c69f544fdb6318b654391ec4be0', '2025-08-11 05:09:48.320323', false, NULL, NULL, '2025-08-04 10:39:48.091195', '2025-08-04 10:39:48.091195', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('842777ca-6ceb-46ac-b66f-5d1305657dc1', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'a4d493ef8f61db2c23439b4009bc008809d5e8f8249427e3c1d6ac6607ecbea8', '2025-08-11 05:10:26.349405', false, NULL, NULL, '2025-08-04 10:40:26.087095', '2025-08-04 10:40:26.087095', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('15f94af6-de09-42b9-8bc9-cdc3670b3f88', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '87447d4fc2833a23565d9af225e28696c40d230e9596616427dde62ead4370bb', '2025-08-11 05:12:52.374393', false, NULL, NULL, '2025-08-04 10:42:52.145148', '2025-08-04 10:42:52.145148', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('01dcec67-e0d0-4266-80d1-2501754f0b6b', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '1630bfca39c943588160465c497023493240acb1ee266c5556ca0b55de3048e7', '2025-08-11 05:28:15.002455', false, NULL, NULL, '2025-08-04 10:58:14.539245', '2025-08-04 10:58:14.539245', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('9bbdd2ae-e924-4e52-9474-b9b6cb613b1d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8cbfad8ef86141d70a0e27e60289942be2f3df95c863b960d229fa2a89c8e5f4', '2025-08-11 05:28:32.585111', false, NULL, NULL, '2025-08-04 10:58:32.168858', '2025-08-04 10:58:32.168858', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('785209b6-f8d6-4b10-927f-8e283758e5c3', 'de9dc531-11bf-4481-882a-dc3291580f60', 'ecf5c5abc91dd6deddf7e32a68e322130c13b2e0ddcdbdaa647a4eae03e9e88d', '2025-08-11 05:29:08.629072', false, NULL, NULL, '2025-08-04 10:59:08.083485', '2025-08-04 10:59:08.083485', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d8244201-4b14-409f-b52a-db3b5e9b0008', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '5aa1711dfaa886f5de9e9906a270fcca7059c85fd1533b0520284e0ba26105ce', '2025-08-11 05:29:18.910448', false, NULL, NULL, '2025-08-04 10:59:18.483243', '2025-08-04 10:59:18.483243', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a12a7fb1-d8e9-487c-b0cd-10945c68377c', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e3db13eb8bc7ef7fec3655c447f6ea017b1b726a24939ea495b74042adb0f5d5', '2025-08-11 05:29:29.776727', false, NULL, NULL, '2025-08-04 10:59:29.269149', '2025-08-04 10:59:29.269149', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5f97e246-4864-4705-9af5-4e778a420e74', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '29688502c983197bed3b06ddb2a0b1f0d198586200eb8f69af8e9213bb276f37', '2025-08-11 05:29:48.638592', false, NULL, NULL, '2025-08-04 10:59:48.192766', '2025-08-04 10:59:48.192766', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5585a09f-ca26-4210-832e-16c1b840df59', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'fbfb70bfe76818edd15d86d54ea4c562a0007a2851cde46013b694161f98abe3', '2025-08-11 05:30:09.648684', false, NULL, NULL, '2025-08-04 11:00:09.246072', '2025-08-04 11:00:09.246072', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d97d6f89-7fd0-4794-a8fd-baf3866c7b34', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2244de19498efacc9f0beb88493ee1dfda04673f97a59d68854ce0272ad048aa', '2025-08-11 05:30:51.267636', false, NULL, NULL, '2025-08-04 11:00:50.699165', '2025-08-04 11:00:50.699165', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6597d1ad-4e2f-46b2-95a6-e9b059cac1e9', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '92e39ad126863588a85e0daafe58b724463a47b912995949cae4212943e69444', '2025-08-11 05:30:59.479411', false, NULL, NULL, '2025-08-04 11:00:59.069079', '2025-08-04 11:00:59.069079', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('ae3ac1f2-915b-4214-a86c-0ff0790becca', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'fa711711d244edd410381a53d4ec4f25717fc30a5db87ea492d432e8b324c563', '2025-08-11 05:31:02.757074', false, NULL, NULL, '2025-08-04 11:01:02.249501', '2025-08-04 11:01:02.249501', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a4a23447-5a1a-42bf-8644-25ed2c0d4855', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5615b8235f4f157396825ec337600395c01b4a30799486d1fadde46ec4156066', '2025-08-11 05:35:33.138907', false, NULL, NULL, '2025-08-04 11:05:32.691808', '2025-08-04 11:05:32.691808', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('35af017b-db73-4286-bc62-b51bee4d8267', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e6961ac21f9c8e6df703581598c684d73cd82ec2062781ac909727768697252e', '2025-08-11 05:36:46.172384', false, NULL, NULL, '2025-08-04 11:06:45.656656', '2025-08-04 11:06:45.656656', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('62713796-5dbd-4ddf-a6dd-5c50a21a3844', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '9c0789f819a7f93d56cdc4cbef27a49c849d791b29789ee92a5bd27b5a69dd80', '2025-08-11 05:37:15.704462', false, NULL, NULL, '2025-08-04 11:07:15.296839', '2025-08-04 11:07:15.296839', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('47216c7f-fa02-453e-ab8f-7a7116a69ea0', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '934282bbc261dcfae3591562356ed071df2912d877066d303eda1957660f319f', '2025-08-11 05:38:19.71945', false, NULL, NULL, '2025-08-04 11:08:19.296181', '2025-08-04 11:08:19.296181', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c96149a7-2824-4aaa-aa96-688e346b919d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8273979e535cd190f2d2969bd89ebd824b5f266cfe93a15522b456fedd72f26a', '2025-08-11 05:41:01.274753', false, NULL, NULL, '2025-08-04 11:11:00.818734', '2025-08-04 11:11:00.818734', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e4bbe7c6-cc63-4324-a717-0aa7b7c5030a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '94cffee812b91ecf86645c56627ad3e2abcd91ef4dc4a416e98e60378299e472', '2025-08-11 05:41:29.430222', false, NULL, NULL, '2025-08-04 11:11:28.993325', '2025-08-04 11:11:28.993325', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('568c7d48-3e00-40f4-b703-389c80c035f7', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8afa94fb6a5f7e4ac22b438e610e6530672a2d4d51fa9cbff19a852e3f88a26b', '2025-08-11 05:01:02.940034', false, NULL, NULL, '2025-08-04 10:31:02.446611', '2025-08-04 10:31:02.446611', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fff928db-1e03-41d3-bacd-3b1f2abd7588', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', '98f0bbbd0fba23b6c678e28842a92ea9f5452d896ad90b056f324b9abd9d4606', '2025-08-11 05:04:08.551518', false, NULL, NULL, '2025-08-04 10:34:08.070198', '2025-08-04 10:34:08.070198', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('6037ee45-dc7c-4aff-8919-cc6190a02001', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'e7effd7a8d973f2887b80ced64a664e2109efc500200710e0733670beefedc72', '2025-08-11 05:04:41.921986', false, NULL, NULL, '2025-08-04 10:34:41.469505', '2025-08-04 10:34:41.469505', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('57510647-4bbe-45ed-af73-9549c6c5babe', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'cbb144f60e4545b1a4dd40768ab1bfea818d5d946646c06d4aab6e17ee2b3f5e', '2025-08-11 05:05:49.325815', false, NULL, NULL, '2025-08-04 10:35:48.764112', '2025-08-04 10:35:48.764112', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e411cc10-792e-4e6c-ae1b-daad49474c22', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '113243553552b82a6a8da59df7cdb0d595ab539d595374ae6d2f1b08595f526c', '2025-08-11 05:07:02.375023', false, NULL, NULL, '2025-08-04 10:37:01.832778', '2025-08-04 10:37:01.832778', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e8658197-bdfa-479c-8eae-90a0dc666f6f', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '4816fb2c7b726557f7d9be9840fd2a30b21c49e0b4df42551543c1bf206c20aa', '2025-08-11 05:07:45.517609', false, NULL, NULL, '2025-08-04 10:37:45.044399', '2025-08-04 10:37:45.044399', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e688cfa9-3a6d-49d5-8067-6cf4045b4bca', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '85b3937b78d3d09dfdc4529a8ae25d82a8183130a8baaf0419055b76e6fddb63', '2025-08-11 05:21:57.451925', false, NULL, NULL, '2025-08-04 10:51:56.843643', '2025-08-04 10:51:56.843643', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('091d0f52-5f6b-457b-b9c8-78a1edb95618', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6e215bba37fc0f49fac211ed189bdd8930607ded9bc43d98cae1998a25a41a8f', '2025-08-11 05:22:09.155292', false, NULL, NULL, '2025-08-04 10:52:08.687178', '2025-08-04 10:52:08.687178', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e2e2ec27-3471-4a99-904e-a08779a90d16', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'fbde17e83fc8f181424b9c0b34c7b19be25e04d333b5ea417139b70c033443bf', '2025-08-11 05:24:39.951949', false, NULL, NULL, '2025-08-04 10:54:39.532651', '2025-08-04 10:54:39.532651', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('0f810894-db6a-4400-aa51-0c42f2089473', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '8c454b0b0f39ff2a72e1b9a2d56dc52ecd38416e000f6a78d8f865dd45eee6fa', '2025-08-12 07:01:24.999432', false, NULL, NULL, '2025-08-05 12:31:24.510541', '2025-08-05 12:31:24.510541', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5896b2d5-0adb-484c-8571-c542992f590a', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'dcd44092b8695f23d0f2224591e9b71972e1d353267d852d07e629aef46f13bb', '2025-09-12 05:01:32.545401', false, NULL, NULL, '2025-09-05 10:31:32.273107', '2025-09-05 10:31:32.273107', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e4268688-fa86-4aa4-8d8b-7ce7289fc0c1', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'c15ea501918dc9fb3db8556b9a65f0b8d6f2c1fe22ba14fe06f158223eb02e28', '2025-09-12 05:07:51.341106', false, NULL, NULL, '2025-09-05 10:37:51.088434', '2025-09-05 10:37:51.088434', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('fc55216b-0bc8-4b87-bf03-64eba24cb8fe', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '84b47f944dd106e4c6df022f819172cd2f2338fee54fcda3b5214039f899bca6', '2025-10-29 17:57:47.444752', false, NULL, NULL, '2025-10-22 23:27:47.114433', '2025-10-22 23:27:47.114433', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('42fe9e5a-db2a-4ee6-85c8-3471f09a9b88', 'de9dc531-11bf-4481-882a-dc3291580f60', 'e245dc2302492762cabcb3d86f8a63ed2422ec210f05b6ce666c28320d80082e', '2025-10-30 02:47:22.786508', false, NULL, NULL, '2025-10-23 08:17:22.295352', '2025-10-23 08:17:22.295352', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('a6adccbd-faad-4d56-806d-97e7b8a4099d', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '87a15ee7a28422e405d0c6a0fdb779b7492e2b979f03a5337e6be7fa677f44ea', '2025-10-30 05:34:48.636447', false, NULL, NULL, '2025-10-23 11:04:48.35815', '2025-10-23 11:04:48.35815', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('b08f89c8-05c1-450a-8a59-2357f508497f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'd2a5d6776be13f10572dbaec0d5f9b433042eb1f8d18501edc489174ad0bebc7', '2025-10-30 05:40:20.537833', false, NULL, NULL, '2025-10-23 11:10:20.24316', '2025-10-23 11:10:20.24316', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5018f0b6-16af-49ba-8bbd-f56997f12263', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6a4d0d7815d081e152ebc0edd82f8b2cfc72979fba98739542b7a684f8a07d7c', '2025-10-30 05:49:50.919611', false, NULL, NULL, '2025-10-23 11:19:50.659308', '2025-10-23 11:19:50.659308', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('be62b60d-3403-420d-9cfa-4fd88347c9a5', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'caf5ae13bfe4cc2aee5247796a7e69159bab98e1adf488c97aebd0a5e0a9b28c', '2025-10-30 05:57:09.244293', false, NULL, NULL, '2025-10-23 11:27:08.986545', '2025-10-23 11:27:08.986545', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('cab20efb-3829-4dc2-88ac-aa68fbb01c29', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'debc66673d66ca3e5a2ef0f4f19c2ff82c4c092c81703ce915e0a3e9bb2fced8', '2025-10-30 05:57:43.693842', false, NULL, NULL, '2025-10-23 11:27:43.406405', '2025-10-23 11:27:43.406405', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('30c01097-a837-4d85-a961-f938ecb59727', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '4660069c40a4ed8607988de9cb282065d3651bae6dcda98f41ca7e651254725a', '2025-10-30 05:59:00.380039', false, NULL, NULL, '2025-10-23 11:29:00.134847', '2025-10-23 11:29:00.134847', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('c98de930-9034-4083-8269-2d62e5261c68', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'ebc7ce69e43f9caa931035d08c09eb68eb427324ee1a16e3178145c5f39d649d', '2025-10-30 05:59:33.113398', false, NULL, NULL, '2025-10-23 11:29:32.865573', '2025-10-23 11:29:32.865573', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4ece6342-2766-457e-a7c3-0f8e364500e7', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'bdff4b8e42bcb4b3e33cb344664a6c4888b8b8b5759b804da196538b4d8a9990', '2025-10-30 05:59:59.623856', false, NULL, NULL, '2025-10-23 11:29:59.361724', '2025-10-23 11:29:59.361724', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('2760d8fd-9aa3-4dfd-ac45-401be417d37d', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '959c05b8ebfdb5aa08bdea4933273ccf28cfd49d805f779fcbe20b9ba9e7793c', '2025-10-30 06:03:30.951639', false, NULL, NULL, '2025-10-23 11:33:30.69517', '2025-10-23 11:33:30.69517', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('f4c4c00f-d534-4bb5-8afe-9bb85a041bb8', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '02f33a1c2db267fb048febcabd6e85bdfdb6f502208c6992741b5d67e9746f92', '2025-10-30 06:06:06.335083', false, NULL, NULL, '2025-10-23 11:36:06.07787', '2025-10-23 11:36:06.07787', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7991fb21-c5e9-4ceb-aacd-38f17409e441', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '556eb7b4dfd90a49deb7a5860432ac3b7b675f01ef9691cb9eb5ade0e27ab8c0', '2025-10-30 06:06:21.994325', false, NULL, NULL, '2025-10-23 11:36:21.740782', '2025-10-23 11:36:21.740782', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('7a9a7753-317a-4295-b8a4-45ffbd902e41', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '163aaa789ead6e9bfd922cf5bb05975379295a2db010bf17eb449ff6dfe73ccc', '2025-10-30 06:06:53.20736', false, NULL, NULL, '2025-10-23 11:36:52.957835', '2025-10-23 11:36:52.957835', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('28171dc9-e4f2-4ffe-a788-8020cc781b86', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'fad11c12a01d679b8189f2d5279f83b6b4fe057ad8d5bb8b43393326037f9696', '2025-10-30 06:08:23.767283', false, NULL, NULL, '2025-10-23 11:38:23.515239', '2025-10-23 11:38:23.515239', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('4860f6c7-712a-417d-b4dd-c830a6af9655', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '612d7f31e7c089e7964c6821e01c1c7f191012cd70b47e3883b0dadb22f3296f', '2025-10-30 06:09:17.367582', false, NULL, NULL, '2025-10-23 11:39:17.109996', '2025-10-23 11:39:17.109996', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('5f221d7a-8db7-4c1c-916a-234e23e45dc7', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'cfa1e55cff2893b736d88a94fde1cea38d3c6c80fd23ff14c8e94bbe6796909b', '2025-10-30 06:10:48.905769', false, NULL, NULL, '2025-10-23 11:40:48.653843', '2025-10-23 11:40:48.653843', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d652c283-07ac-48d5-866b-9841480be2ec', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'c5da549bc2166e9565e70820437c804bf06d0f8c27547b9765936e620aa10b70', '2025-10-30 06:11:15.662064', false, NULL, NULL, '2025-10-23 11:41:15.40732', '2025-10-23 11:41:15.40732', NULL, NULL);


--
-- TOC entry 3805 (class 0 OID 31126)
-- Dependencies: 252
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users VALUES ('839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', NULL, 'System ', 'main', NULL, NULL, NULL, '2025-07-18 06:57:17.482', '2025-08-04 11:10:05.594788', NULL, NULL, '');
INSERT INTO public.users VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '200325314526', 'Thidas', 'Senanayeka', 'Colombo', '0765898755', '2003-01-01', '2025-07-18 07:09:21.535', '2025-08-04 11:10:05.59889', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'ns@gmail.com');
INSERT INTO public.users VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '200135645879', 'Umaya', 'Jayasuriya', 'Jaffna', '045789866', '2004-10-10', '2025-07-18 14:04:14.712', '2025-08-04 11:10:05.60281', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'umayal@gmail.com');
INSERT INTO public.users VALUES ('75cf1bda-3240-41c5-8235-5a0f06d51fa7', '200135645870', 'Deshan', 'Nipun', 'Galle', '045789866', '2004-10-10', '2025-07-18 14:18:45.238', '2025-08-04 11:10:05.606733', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'Sunimal@gmail.com');
INSERT INTO public.users VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '200325314527', 'Malindu', 'Bandara', 'Nugegoda', '0765898745', '2003-01-01', '2025-07-18 07:19:23.418', '2025-08-04 11:10:05.61162', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'cse23@gmail.co');


--
-- TOC entry 3806 (class 0 OID 31132)
-- Dependencies: 253
-- Data for Name: users_branch; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users_branch VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3dd6870c-e6f2-414d-9973-309ba00ce115');
INSERT INTO public.users_branch VALUES ('75cf1bda-3240-41c5-8235-5a0f06d51fa7', '57438d7f-184f-42fe-b0d6-91a2ef609beb');
INSERT INTO public.users_branch VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '50cf15c8-b810-4a5c-8400-79cfe791aba4');
INSERT INTO public.users_branch VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '3736a1a3-5fdc-455e-96be-1269df99e9a5');


--
-- TOC entry 3807 (class 0 OID 31135)
-- Dependencies: 254
-- Data for Name: users_role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users_role VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '88e07160-2df2-4d18-ab38-9b4668267956');
INSERT INTO public.users_role VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '05865b54-4591-4ccb-b1b8-bacf4c8771a2');
INSERT INTO public.users_role VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '6b238ef4-bce5-4c9a-85d6-795178e85ea3');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '05865b54-4591-4ccb-b1b8-bacf4c8771a2');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5d8461b9-9f7d-4c8e-8306-91760ef30a9b');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b116c56-efe7-45eb-883b-b3e7d5f68145');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '34dbe9a4-95a3-4abb-9442-5a78ea632af9');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b238ef4-bce5-4c9a-85d6-795178e85ea3');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '17e15824-573e-4bdd-8079-1daabc0a563b');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '87b01ec1-46ba-42bb-975b-4d25c16582b6');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '88e07160-2df2-4d18-ab38-9b4668267956');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '1f65261b-a275-4b10-a71d-a556f3525428');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '934d3f0b-e687-4de3-8e70-bdc9cbc775bf');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3765a6c7-6ac2-4faf-9f71-3088378b3fdd');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'fe6b7dfa-8e54-4539-8bb6-3546e26ccd30');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '9c3adbb6-6ae6-4800-a65b-f78e78649078');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'b7ce085d-d88e-4291-a0ab-efcc14a1ae3e');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'ce1a460c-e571-48b7-8b21-1d4aac270849');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '49cc2c12-f54e-4088-a129-678e6aec7312');
INSERT INTO public.users_role VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'fe6b7dfa-8e54-4539-8bb6-3546e26ccd30');
INSERT INTO public.users_role VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'ce1a460c-e571-48b7-8b21-1d4aac270849');


--
-- TOC entry 3816 (class 0 OID 0)
-- Dependencies: 255
-- Name: jobid_seq; Type: SEQUENCE SET; Schema: cron; Owner: -
--

SELECT pg_catalog.setval('cron.jobid_seq', 6, true);


--
-- TOC entry 3817 (class 0 OID 0)
-- Dependencies: 257
-- Name: runid_seq; Type: SEQUENCE SET; Schema: cron; Owner: -
--

SELECT pg_catalog.setval('cron.runid_seq', 1, false);


--
-- TOC entry 3519 (class 2606 OID 31139)
-- Name: account account_account_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_account_no_key UNIQUE (account_no);


--
-- TOC entry 3521 (class 2606 OID 31141)
-- Name: account account_no_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_no_unique UNIQUE (account_no);


--
-- TOC entry 3523 (class 2606 OID 31143)
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (acc_id);


--
-- TOC entry 3527 (class 2606 OID 31145)
-- Name: accounts_owner accounts_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_pkey PRIMARY KEY (acc_id, customer_id);


--
-- TOC entry 3529 (class 2606 OID 31147)
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id);


--
-- TOC entry 3534 (class 2606 OID 31149)
-- Name: branch branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_pkey PRIMARY KEY (branch_id);


--
-- TOC entry 3542 (class 2606 OID 31151)
-- Name: customer_login customer_login_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_key UNIQUE (customer_id);


--
-- TOC entry 3544 (class 2606 OID 31153)
-- Name: customer_login customer_login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3546 (class 2606 OID 31155)
-- Name: customer_login customer_login_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_username_key UNIQUE (username);


--
-- TOC entry 3536 (class 2606 OID 31468)
-- Name: customer customer_nic_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_nic_key UNIQUE (nic);


--
-- TOC entry 3538 (class 2606 OID 31159)
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- TOC entry 3548 (class 2606 OID 31161)
-- Name: fd_plan fd_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_pkey PRIMARY KEY (fd_plan_id);


--
-- TOC entry 3550 (class 2606 OID 31163)
-- Name: fixed_deposit fixed_deposit_fd_account_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_fd_account_no_key UNIQUE (fd_account_no);


--
-- TOC entry 3552 (class 2606 OID 31165)
-- Name: fixed_deposit fixed_deposit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_pkey PRIMARY KEY (fd_id);


--
-- TOC entry 3556 (class 2606 OID 31167)
-- Name: login login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_pkey PRIMARY KEY (log_id);


--
-- TOC entry 3558 (class 2606 OID 31169)
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (role_id);


--
-- TOC entry 3560 (class 2606 OID 31171)
-- Name: role role_role_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_role_name_key UNIQUE (role_name);


--
-- TOC entry 3562 (class 2606 OID 31173)
-- Name: savings_plan savings_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_pkey PRIMARY KEY (savings_plan_id);


--
-- TOC entry 3567 (class 2606 OID 31175)
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (transaction_id);


--
-- TOC entry 3569 (class 2606 OID 31177)
-- Name: transactions transactions_reference_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_reference_no_key UNIQUE (reference_no);


--
-- TOC entry 3571 (class 2606 OID 31179)
-- Name: user_login user_login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3573 (class 2606 OID 31181)
-- Name: user_login user_login_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_key UNIQUE (user_id);


--
-- TOC entry 3575 (class 2606 OID 31183)
-- Name: user_login user_login_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_username_key UNIQUE (username);


--
-- TOC entry 3581 (class 2606 OID 31185)
-- Name: user_refresh_tokens user_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_pkey PRIMARY KEY (token_id);


--
-- TOC entry 3589 (class 2606 OID 31187)
-- Name: users_branch users_branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_pkey PRIMARY KEY (user_id, branch_id);


--
-- TOC entry 3585 (class 2606 OID 31189)
-- Name: users users_nic_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_nic_key UNIQUE (nic);


--
-- TOC entry 3587 (class 2606 OID 31191)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- TOC entry 3591 (class 2606 OID 31193)
-- Name: users_role users_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_pkey PRIMARY KEY (user_id, role_id);


--
-- TOC entry 3524 (class 1259 OID 31194)
-- Name: idx_account_account_no; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_account_no ON public.account USING btree (account_no);


--
-- TOC entry 3525 (class 1259 OID 31195)
-- Name: idx_account_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_branch_id ON public.account USING btree (branch_id);


--
-- TOC entry 3530 (class 1259 OID 31196)
-- Name: idx_audit_log_table_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_table_record ON public.audit_log USING btree (table_name, record_id);


--
-- TOC entry 3531 (class 1259 OID 31197)
-- Name: idx_audit_log_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_timestamp ON public.audit_log USING btree ("timestamp");


--
-- TOC entry 3532 (class 1259 OID 31198)
-- Name: idx_audit_log_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_user_id ON public.audit_log USING btree (user_id);


--
-- TOC entry 3539 (class 1259 OID 31199)
-- Name: idx_customer_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_created_at ON public.customer USING btree (created_at);


--
-- TOC entry 3540 (class 1259 OID 31469)
-- Name: idx_customer_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_nic ON public.customer USING btree (nic);


--
-- TOC entry 3553 (class 1259 OID 31201)
-- Name: idx_login_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_time ON public.login USING btree (login_time);


--
-- TOC entry 3554 (class 1259 OID 31202)
-- Name: idx_login_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_user_id ON public.login USING btree (user_id);


--
-- TOC entry 3563 (class 1259 OID 31203)
-- Name: idx_transactions_acc_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_acc_id ON public.transactions USING btree (acc_id);


--
-- TOC entry 3564 (class 1259 OID 31204)
-- Name: idx_transactions_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at);


--
-- TOC entry 3565 (class 1259 OID 31205)
-- Name: idx_transactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_type ON public.transactions USING btree (type);


--
-- TOC entry 3576 (class 1259 OID 31206)
-- Name: idx_user_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_expires_at ON public.user_refresh_tokens USING btree (expires_at);


--
-- TOC entry 3577 (class 1259 OID 31207)
-- Name: idx_user_refresh_tokens_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_hash ON public.user_refresh_tokens USING btree (token_hash);


--
-- TOC entry 3578 (class 1259 OID 31208)
-- Name: idx_user_refresh_tokens_revoked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_revoked ON public.user_refresh_tokens USING btree (is_revoked);


--
-- TOC entry 3579 (class 1259 OID 31209)
-- Name: idx_user_refresh_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_user_id ON public.user_refresh_tokens USING btree (user_id);


--
-- TOC entry 3582 (class 1259 OID 31210)
-- Name: idx_users_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_created_at ON public.users USING btree (created_at);


--
-- TOC entry 3583 (class 1259 OID 31211)
-- Name: idx_users_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_nic ON public.users USING btree (nic);


--
-- TOC entry 3634 (class 2620 OID 31212)
-- Name: account update_account_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_account_updated_at BEFORE UPDATE ON public.account FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3635 (class 2620 OID 31213)
-- Name: branch update_branch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_branch_updated_at BEFORE UPDATE ON public.branch FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3637 (class 2620 OID 31214)
-- Name: customer_login update_customer_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_login_updated_at BEFORE UPDATE ON public.customer_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3636 (class 2620 OID 31215)
-- Name: customer update_customer_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_updated_at BEFORE UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3638 (class 2620 OID 31216)
-- Name: fd_plan update_fd_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fd_plan_updated_at BEFORE UPDATE ON public.fd_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3639 (class 2620 OID 31217)
-- Name: fixed_deposit update_fixed_deposit_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fixed_deposit_updated_at BEFORE UPDATE ON public.fixed_deposit FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3640 (class 2620 OID 31218)
-- Name: savings_plan update_savings_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_savings_plan_updated_at BEFORE UPDATE ON public.savings_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3641 (class 2620 OID 31219)
-- Name: user_login update_user_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_login_updated_at BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3643 (class 2620 OID 31220)
-- Name: user_refresh_tokens update_user_refresh_tokens_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_refresh_tokens_updated_at BEFORE UPDATE ON public.user_refresh_tokens FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3644 (class 2620 OID 31221)
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3642 (class 2620 OID 31222)
-- Name: user_login user_login_update_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_login_update_audit BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.audit_user_login_update();


--
-- TOC entry 3598 (class 2606 OID 31223)
-- Name: account account_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3599 (class 2606 OID 31228)
-- Name: account account_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3600 (class 2606 OID 31233)
-- Name: account account_savings_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_savings_plan_id_fkey FOREIGN KEY (savings_plan_id) REFERENCES public.savings_plan(savings_plan_id);


--
-- TOC entry 3601 (class 2606 OID 31238)
-- Name: account account_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3602 (class 2606 OID 31243)
-- Name: accounts_owner accounts_owner_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3603 (class 2606 OID 31248)
-- Name: accounts_owner accounts_owner_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- TOC entry 3604 (class 2606 OID 31253)
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3605 (class 2606 OID 31258)
-- Name: branch branch_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3606 (class 2606 OID 31263)
-- Name: branch branch_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3607 (class 2606 OID 31268)
-- Name: customer customer_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3609 (class 2606 OID 31273)
-- Name: customer_login customer_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3610 (class 2606 OID 31278)
-- Name: customer_login customer_login_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON DELETE CASCADE;


--
-- TOC entry 3611 (class 2606 OID 31283)
-- Name: customer_login customer_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3608 (class 2606 OID 31288)
-- Name: customer customer_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3612 (class 2606 OID 31293)
-- Name: fd_plan fd_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3613 (class 2606 OID 31298)
-- Name: fd_plan fd_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3614 (class 2606 OID 31303)
-- Name: fixed_deposit fixed_deposit_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3615 (class 2606 OID 31308)
-- Name: fixed_deposit fixed_deposit_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3616 (class 2606 OID 31313)
-- Name: fixed_deposit fixed_deposit_fd_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_fd_plan_id_fkey FOREIGN KEY (fd_plan_id) REFERENCES public.fd_plan(fd_plan_id);


--
-- TOC entry 3617 (class 2606 OID 31318)
-- Name: fixed_deposit fixed_deposit_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3618 (class 2606 OID 31323)
-- Name: login login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3619 (class 2606 OID 31328)
-- Name: savings_plan savings_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3620 (class 2606 OID 31333)
-- Name: savings_plan savings_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3621 (class 2606 OID 31338)
-- Name: transactions transactions_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3622 (class 2606 OID 31343)
-- Name: transactions transactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3623 (class 2606 OID 31348)
-- Name: user_login user_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3624 (class 2606 OID 31353)
-- Name: user_login user_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3625 (class 2606 OID 31358)
-- Name: user_login user_login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- TOC entry 3626 (class 2606 OID 31363)
-- Name: user_refresh_tokens user_refresh_tokens_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES public.users(user_id);


--
-- TOC entry 3627 (class 2606 OID 31368)
-- Name: user_refresh_tokens user_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3630 (class 2606 OID 31373)
-- Name: users_branch users_branch_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3631 (class 2606 OID 31378)
-- Name: users_branch users_branch_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3628 (class 2606 OID 31383)
-- Name: users users_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3632 (class 2606 OID 31388)
-- Name: users_role users_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(role_id);


--
-- TOC entry 3633 (class 2606 OID 31393)
-- Name: users_role users_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3629 (class 2606 OID 31398)
-- Name: users users_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


-- Completed on 2025-10-23 12:06:53 +0530

--
-- PostgreSQL database dump complete
--

