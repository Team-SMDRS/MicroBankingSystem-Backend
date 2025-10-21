--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

-- Started on 2025-10-21 18:43:47 +0530

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
-- TOC entry 3801 (class 0 OID 0)
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
-- TOC entry 3802 (class 0 OID 0)
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
-- TOC entry 3803 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- TOC entry 950 (class 1247 OID 30961)
-- Name: account_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.account_status AS ENUM (
    'active',
    'frozen',
    'closed'
);


--
-- TOC entry 953 (class 1247 OID 30968)
-- Name: audit_action; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.audit_action AS ENUM (
    'INSERT',
    'UPDATE',
    'DELETE'
);


--
-- TOC entry 956 (class 1247 OID 30976)
-- Name: status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.status_enum AS ENUM (
    'active',
    'inactive'
);


--
-- TOC entry 959 (class 1247 OID 30982)
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
-- TOC entry 252 (class 1255 OID 30993)
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
-- TOC entry 315 (class 1255 OID 30994)
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
-- TOC entry 307 (class 1255 OID 30995)
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
-- TOC entry 297 (class 1255 OID 30996)
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
-- TOC entry 326 (class 1255 OID 30997)
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
-- TOC entry 283 (class 1255 OID 30998)
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
-- TOC entry 282 (class 1255 OID 30999)
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
-- TOC entry 320 (class 1255 OID 31000)
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
-- TOC entry 310 (class 1255 OID 31492)
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
-- TOC entry 279 (class 1255 OID 31481)
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
-- TOC entry 319 (class 1255 OID 31002)
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
-- TOC entry 311 (class 1255 OID 31477)
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
-- TOC entry 294 (class 1255 OID 31004)
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
-- TOC entry 299 (class 1255 OID 31005)
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
-- TOC entry 325 (class 1255 OID 31490)
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
-- TOC entry 275 (class 1255 OID 31006)
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
-- TOC entry 251 (class 1255 OID 31007)
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
-- TOC entry 284 (class 1255 OID 31463)
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
-- TOC entry 249 (class 1255 OID 31009)
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
-- TOC entry 286 (class 1255 OID 31010)
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
-- TOC entry 317 (class 1255 OID 31011)
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
-- TOC entry 321 (class 1255 OID 31012)
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
-- TOC entry 329 (class 1255 OID 31013)
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
-- TOC entry 265 (class 1255 OID 31014)
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
-- TOC entry 285 (class 1255 OID 31478)
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
-- TOC entry 295 (class 1255 OID 31016)
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
-- TOC entry 261 (class 1255 OID 31489)
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
-- TOC entry 303 (class 1255 OID 31017)
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
-- TOC entry 255 (class 1255 OID 31018)
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
-- TOC entry 293 (class 1255 OID 31019)
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
-- TOC entry 262 (class 1255 OID 31020)
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
-- TOC entry 226 (class 1259 OID 31021)
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
-- TOC entry 227 (class 1259 OID 31030)
-- Name: accounts_owner; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts_owner (
    acc_id uuid NOT NULL,
    customer_id uuid NOT NULL
);


--
-- TOC entry 228 (class 1259 OID 31033)
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
-- TOC entry 229 (class 1259 OID 31040)
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
-- TOC entry 230 (class 1259 OID 31046)
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
-- TOC entry 231 (class 1259 OID 31052)
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
-- TOC entry 232 (class 1259 OID 31061)
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
-- TOC entry 233 (class 1259 OID 31068)
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
-- TOC entry 234 (class 1259 OID 31077)
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
    a.account_no,
    b.name AS branch_name,
    fp.duration AS plan_duration,
    fp.interest_rate AS plan_interest_rate,
    fd.status,
    fd.next_interest_day
   FROM (((public.fixed_deposit fd
     LEFT JOIN public.account a ON ((fd.acc_id = a.acc_id)))
     LEFT JOIN public.branch b ON ((a.branch_id = b.branch_id)))
     LEFT JOIN public.fd_plan fp ON ((fd.fd_plan_id = fp.fd_plan_id)));


--
-- TOC entry 235 (class 1259 OID 31082)
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
-- TOC entry 236 (class 1259 OID 31089)
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role (
    role_id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_name character varying(50) NOT NULL
);


--
-- TOC entry 237 (class 1259 OID 31093)
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
-- TOC entry 238 (class 1259 OID 31099)
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
-- TOC entry 239 (class 1259 OID 31107)
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
-- TOC entry 240 (class 1259 OID 31117)
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
-- TOC entry 241 (class 1259 OID 31126)
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
-- TOC entry 242 (class 1259 OID 31132)
-- Name: users_branch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_branch (
    user_id uuid NOT NULL,
    branch_id uuid NOT NULL
);


--
-- TOC entry 243 (class 1259 OID 31135)
-- Name: users_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_role (
    user_id uuid NOT NULL,
    role_id uuid NOT NULL
);


--
-- TOC entry 3444 (class 0 OID 31410)
-- Dependencies: 245
-- Data for Name: job; Type: TABLE DATA; Schema: cron; Owner: -
--

INSERT INTO cron.job VALUES (1, '5 0 1 * *', '
    SELECT calculate_monthly_interest();
    ', 'localhost', 5432, 'postgres', 'postgres', true, 'monthly_interest_job');
INSERT INTO cron.job VALUES (6, '0 0 * * *', 'SELECT daily_fd_interest_check()', 'localhost', 5432, 'postgres', 'postgres', true, 'fd-interest-daily');


--
-- TOC entry 3446 (class 0 OID 31429)
-- Dependencies: 247
-- Data for Name: job_run_details; Type: TABLE DATA; Schema: cron; Owner: -
--



--
-- TOC entry 3779 (class 0 OID 31021)
-- Dependencies: 226
-- Data for Name: account; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.account VALUES ('b0134b68-04e3-4e00-a0ac-dabe67c9612f', 2770729143, '3dd6870c-e6f2-414d-9973-309ba00ce115', '75cb0dfb-be48-4b4c-ab13-9e01772f0332', 114185.083580409082, '2025-10-14 15:32:34.730917', '2025-10-14 15:32:34.730917', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('58f8da96-a4c1-4071-8a8c-a195b70bb040', 2815823974, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 419890.637258498507, '2025-09-24 17:50:34.479023', '2025-09-24 17:50:34.479023', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('820e7b5a-8b66-4242-b7e0-a49e9880b17e', 5641582760, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 6808.410382365626, '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('c1e74ae4-f466-4769-9649-f8064a7e6a89', 6052845866, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 5315.101869623545, '2025-09-24 14:56:44.494199', '2025-09-24 14:56:44.494199', '2025-10-21 10:30:24.968406', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('1b337986-ae2d-4e9e-9f87-5bd92e29253f', 1234567890, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 1015.676389191086, '2025-09-18 13:56:05.448161', '2025-09-18 13:56:05.448161', '2025-10-20 16:08:57.374798', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('31d95fe1-7d2f-4d9e-81c1-b608131b7335', 1623490919, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 23.265418877838, '2025-10-15 10:39:31.756196', '2025-10-15 10:39:31.756196', '2025-10-20 16:08:57.374798', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('3337ad45-7e90-4c8f-9057-e38f3c43f196', 1111111111, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 39108.199539172789, '2025-09-18 14:43:34.844831', '2025-09-18 14:43:34.844831', '2025-10-21 17:40:31.017145', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.account VALUES ('e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 8120354779, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 2076.812921498341, '2025-09-24 19:39:23.999379', '2025-09-24 19:39:23.999379', '2025-10-20 16:08:57.374798', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('fb762c41-c883-4bba-9bcf-f59dfc07f042', 1529729150, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 1016.505911052731, '2025-10-15 00:55:47.52668', '2025-10-15 00:55:47.52668', '2025-10-20 16:08:57.374798', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('8f453f53-bf51-437c-b8a9-702b08caf92d', 2252112086, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 0.000000000000, '2025-10-15 11:01:38.812598', '2025-10-15 11:01:38.812598', '2025-10-20 16:09:31.425969', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('0415f29e-fb5b-4756-baa6-bce59cab2be5', 9740325119, '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 1008.219178082192, '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '2025-10-20 16:09:31.427788', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 123456789, '57438d7f-184f-42fe-b0d6-91a2ef609beb', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 2058.401096928214, '2025-09-18 14:07:15.807623', '2025-09-18 14:07:15.807623', '2025-10-20 16:09:31.43024', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'active');
INSERT INTO public.account VALUES ('fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 5233589009, '3dd6870c-e6f2-414d-9973-309ba00ce115', 'fd8afec3-3da2-48ab-a63d-abbff3a3e773', 8954.329013773691, '2025-10-15 09:22:06.611902', '2025-10-15 09:22:06.611902', '2025-10-20 16:08:57.374798', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');
INSERT INTO public.account VALUES ('fde6ebe4-72be-4574-a470-999a365b1529', 8283584064, '3dd6870c-e6f2-414d-9973-309ba00ce115', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 1219.453424657534, '2025-10-15 01:47:09.659802', '2025-10-15 01:47:09.659802', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');


--
-- TOC entry 3780 (class 0 OID 31030)
-- Dependencies: 227
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


--
-- TOC entry 3781 (class 0 OID 31033)
-- Dependencies: 228
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


--
-- TOC entry 3782 (class 0 OID 31040)
-- Dependencies: 229
-- Data for Name: branch; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.branch VALUES ('57438d7f-184f-42fe-b0d6-91a2ef609beb', 'Jafna', 'Jafna', '2025-09-18 07:07:02.375386', '2025-09-18 07:07:02.375386', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1');
INSERT INTO public.branch VALUES ('3639c0dc-bda3-472e-8a06-5f8a4e36c42a', 'fef', 'wee', '2025-10-14 13:14:51.355254', '2025-10-14 13:14:51.355254', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.branch VALUES ('3736a1a3-5fdc-455e-96be-1269df99e9a5', 'fvdf', 'dvv', '2025-10-15 02:10:06.066924', '2025-10-15 02:10:06.066924', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.branch VALUES ('50cf15c8-b810-4a5c-8400-79cfe791aba4', 'Moratuwa', 'Katubadda, Moratuwa', '2025-10-04 01:23:35.796972', '2025-10-15 02:10:49.306436', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.branch VALUES ('3dd6870c-e6f2-414d-9973-309ba00ce115', 'Colombo', 'colombore', '2025-09-18 07:05:43.839001', '2025-10-15 02:18:47.643502', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.branch VALUES ('12af5190-d280-4842-addf-6c66312b4ffc', 'UOM branch', 'katubedda', '2025-10-15 02:19:49.448874', '2025-10-17 19:41:38.426306', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');


--
-- TOC entry 3783 (class 0 OID 31046)
-- Dependencies: 230
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.customer VALUES ('12d17661-847d-4385-9fd2-ea582da813b2', 'customer 3', 'colombo', '0745879866', '200147897589', '2025-09-18 14:33:26.650656', '2025-09-18 14:33:26.650656', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-02-06');
INSERT INTO public.customer VALUES ('4ab20e7b-e5c7-4331-b75d-2135c62c4ac7', 'customer 8', 'moratuwa', '0721458654', '200302154789', '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2003-10-10');
INSERT INTO public.customer VALUES ('97da5431-f39a-43e5-b0cd-9d185327b6e6', 'new name', 'new address', '0465879523', '211454546587', '2025-09-18 14:41:28.403699', '2025-10-15 03:27:14.502344', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-02-06');
INSERT INTO public.customer VALUES ('96a6ea17-b2d3-40d0-9c5b-903da6280f50', 'customer 1', 'jafna', '0724548799', '20045454654', '2025-09-18 14:29:18.039149', '2025-10-15 03:36:44.284379', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-02-06');
INSERT INTO public.customer VALUES ('8f99e4a7-47ed-44ea-947f-89dae567a52c', 'customer7', 'string', 'string', '200254545879', '2025-09-24 17:50:34.479023', '2025-10-15 03:37:09.790343', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-11-11');
INSERT INTO public.customer VALUES ('277ccc80-9a20-438e-93a9-459f041b145d', '1212', 'eqdwda', '0778877546', '321656332323', '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2025-10-09');
INSERT INTO public.customer VALUES ('f0bf0ef8-0015-4c79-bae4-bab26d897409', 'new name 2', 'new addres', '07553122', '20058795645', '2025-09-18 14:29:55.137535', '2025-10-15 12:37:03.439601', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-02-06');


--
-- TOC entry 3784 (class 0 OID 31052)
-- Dependencies: 231
-- Data for Name: customer_login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.customer_login VALUES ('657f315a-9b6a-4c54-a3d1-b72fa645c7f5', '97da5431-f39a-43e5-b0cd-9d185327b6e6', 'mycustomer', '$2a$12$7gXkpFQmcoCPFx39ssSJb.FcJNK8opQzlLU5z5XcoYJEpcKZjWthm', '2025-09-19 02:18:40.386038', '2025-09-19 02:18:40.386038', '2025-09-19 02:18:40.386038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('bf23810f-9d8e-411a-b7f8-661766306774', '8f99e4a7-47ed-44ea-947f-89dae567a52c', 'customer70757', 'Bs3ewE5Q', '2025-09-24 17:50:34.479023', '2025-09-24 17:50:34.479023', '2025-09-24 17:50:34.479023', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('8c72a1ba-8252-4e9f-a0df-9d1491d8bcce', '4ab20e7b-e5c7-4331-b75d-2135c62c4ac7', 'customer86624', 'C6YMxxWN', '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '2025-10-03 17:30:50.915495', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.customer_login VALUES ('764f801e-4662-4c9f-928e-078ad141d743', '277ccc80-9a20-438e-93a9-459f041b145d', '12120703', '$2b$12$ut9A5rTddWH9A9Vna3XbeO4F0B6wTAClKaNaj0tsTRr60jnavCl26', '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '2025-10-15 10:42:47.042038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');


--
-- TOC entry 3785 (class 0 OID 31061)
-- Dependencies: 232
-- Data for Name: fd_plan; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fd_plan VALUES ('f6248a43-7311-4741-bf69-9e3628df3cee', 12, 14.00, '2025-09-18 13:37:13.906323', '2025-09-18 13:37:13.906323', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('fede8a9f-d3a5-4aee-a763-e43eae84397f', 36, 15.00, '2025-09-18 13:37:13.907726', '2025-09-18 13:37:13.907726', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('b44091ce-db91-4597-bc76-d4964b6470b5', 25, 12.00, '2025-10-03 18:59:19.17747', '2025-10-03 19:02:32.16124', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('3c603a19-3cb0-4b8d-8e78-eecb0dfbbecf', 14, 25.00, '2025-10-14 12:52:42.206518', '2025-10-14 12:52:42.206518', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('2155b849-ea21-4703-8fbf-385cd99be5d7', 44, 14.00, '2025-10-04 06:54:03.74637', '2025-10-20 16:46:23.501296', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('2e3ea02d-2fab-44c9-81f0-f10f0b872bbc', 112, 11.00, '2025-10-14 21:53:50.42115', '2025-10-20 16:46:26.142673', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('aba51ea9-6174-4a6e-8463-6d03dd717185', 6, 13.00, '2025-09-18 13:37:13.902794', '2025-10-20 17:17:06.030708', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'inactive', 50000);
INSERT INTO public.fd_plan VALUES ('5ad7e9a8-b823-4d2a-a450-2d6de934cf8b', 12, 5.00, '2025-10-20 17:17:28.614594', '2025-10-20 17:17:28.614594', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 50000);
INSERT INTO public.fd_plan VALUES ('c8500f42-a3c4-4aa3-9396-7395ac4e35fb', 11, 5.00, '2025-10-21 15:59:16.116847', '2025-10-21 15:59:16.116847', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active', 15000);


--
-- TOC entry 3786 (class 0 OID 31068)
-- Dependencies: 233
-- Data for Name: fixed_deposit; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fixed_deposit VALUES ('4139dfa5-f386-4ec6-a87b-1647053b4f1d', 122222.000000000000, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', '2025-10-04 06:53:28.176285', '2028-10-04 06:53:28.176285', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-10-04 06:53:28.176285', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 34750437, 'active', '2025-11-19');
INSERT INTO public.fixed_deposit VALUES ('200e5c3c-035f-41b2-9c71-0efde9f3cfe3', 100000.000000000000, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', '2025-10-14 12:51:37.948395', '2027-11-14 12:51:37.948395', 'b44091ce-db91-4597-bc76-d4964b6470b5', '2025-10-14 12:51:37.948395', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 74226670, 'active', '2025-11-19');
INSERT INTO public.fixed_deposit VALUES ('cb591d9c-c63d-4228-824f-d0c8a54b3f73', 5000.000000000000, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', '2025-10-03 22:03:31.130479', '2028-10-03 22:03:31.130479', 'fede8a9f-d3a5-4aee-a763-e43eae84397f', '2025-10-03 22:03:31.130479', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 83370957, 'active', '2025-11-19');
INSERT INTO public.fixed_deposit VALUES ('391014f1-8057-41db-9426-d211030f4912', 50000.000000000000, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', '2025-10-20 21:32:10.386211', '2029-06-20 21:32:10.386211', '2155b849-ea21-4703-8fbf-385cd99be5d7', '2025-10-20 21:32:10.386211', '2025-10-20 21:32:10.386211', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 46224124, 'active', '2025-11-19');
INSERT INTO public.fixed_deposit VALUES ('a00ad7b9-2533-4b17-be68-011f38ceaf73', 10000.000000000000, 'fde6ebe4-72be-4574-a470-999a365b1529', '2025-10-20 02:56:18.352714', '2026-04-20 02:56:18.352714', 'aba51ea9-6174-4a6e-8463-6d03dd717185', '2025-10-20 02:56:18.352714', '2025-10-21 06:39:41.196182', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 50025993, 'active', '2025-11-20');
INSERT INTO public.fixed_deposit VALUES ('27825487-c485-40c0-8746-0fdd56bd852a', 252150.000000000000, '0415f29e-fb5b-4756-baa6-bce59cab2be5', '2025-10-21 17:32:04.600958', '2027-11-21 17:32:04.600958', 'b44091ce-db91-4597-bc76-d4964b6470b5', '2025-10-21 17:32:04.600958', '2025-10-21 17:32:04.600958', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 42626950, 'active', '2025-11-20');
INSERT INTO public.fixed_deposit VALUES ('b8307b15-a9f4-4106-bd17-ca67231f7c4c', 90000.000000000000, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', '2025-10-17 12:41:40.232013', '2026-10-17 12:41:40.232013', 'f6248a43-7311-4741-bf69-9e3628df3cee', '2025-10-17 12:41:40.232013', '2025-10-20 16:54:04.103615', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 92204927, 'active', '2025-11-19');


--
-- TOC entry 3787 (class 0 OID 31082)
-- Dependencies: 235
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


--
-- TOC entry 3788 (class 0 OID 31089)
-- Dependencies: 236
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.role VALUES ('88e07160-2df2-4d18-ab38-9b4668267956', 'withdrawal');
INSERT INTO public.role VALUES ('1f65261b-a275-4b10-a71d-a556f3525428', 'deposit');
INSERT INTO public.role VALUES ('05865b54-4591-4ccb-b1b8-bacf4c8771a2', 'account-open');
INSERT INTO public.role VALUES ('87b01ec1-46ba-42bb-975b-4d25c16582b6', 'account-close');
INSERT INTO public.role VALUES ('b7ce085d-d88e-4291-a0ab-efcc14a1ae3e', 'transaction');
INSERT INTO public.role VALUES ('5d8461b9-9f7d-4c8e-8306-91760ef30a9b', 'fd-create');
INSERT INTO public.role VALUES ('6b116c56-efe7-45eb-883b-b3e7d5f68145', 'fd-close');
INSERT INTO public.role VALUES ('a4ea6418-2b71-4c93-804e-befb747f876a', 'customer-create');
INSERT INTO public.role VALUES ('34dbe9a4-95a3-4abb-9442-5a78ea632af9', 'user-create');


--
-- TOC entry 3789 (class 0 OID 31093)
-- Dependencies: 237
-- Data for Name: savings_plan; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.savings_plan VALUES ('7d8f328d-650d-4e19-b2ef-4c7292f6264a', 'Joint', 7.00, '2025-09-18 10:27:13.250715', '2025-10-14 21:05:51.619325', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 5000);
INSERT INTO public.savings_plan VALUES ('75cb0dfb-be48-4b4c-ab13-9e01772f0332', 'Children', 12.00, '2025-09-18 13:35:04.860764', '2025-10-14 21:05:51.620268', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 0);
INSERT INTO public.savings_plan VALUES ('fd8afec3-3da2-48ab-a63d-abbff3a3e773', 'Senior', 13.00, '2025-10-14 21:05:51.612605', '2025-10-14 21:06:17.110416', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 1000);
INSERT INTO public.savings_plan VALUES ('a620a5c0-9456-4bc6-a37c-1c02d8f0da9c', 'Teen', 11.00, '2025-10-14 21:05:51.615497', '2025-10-14 21:06:17.112064', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 500);
INSERT INTO public.savings_plan VALUES ('3678e0b0-2c29-4df6-9744-c311254361b1', 'stringg', 10.00, '2025-10-15 14:14:07.066356', '2025-10-15 14:14:07.066356', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 100);
INSERT INTO public.savings_plan VALUES ('3578bd55-8c57-4757-aa7b-0f37b859edd6', 'Adult', 10.00, '2025-09-18 10:25:36.776016', '2025-10-20 17:19:47.349057', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 1000);


--
-- TOC entry 3790 (class 0 OID 31099)
-- Dependencies: 238
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.transactions VALUES ('f6b92d76-0ac1-4b96-aabc-05cbbb3db8f7', 100.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Deposit', 'damma2', '2025-10-04 11:20:02.009178', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 488281374005011);
INSERT INTO public.transactions VALUES ('45a5dff5-5d6c-485e-86e8-edbd25e74230', 199.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Withdrawal', 'gaththa1', '2025-10-04 11:22:56.51151', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 522854710418057);
INSERT INTO public.transactions VALUES ('f6266406-5455-4650-8d08-b77f402a5167', 1.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-04 11:26:19.597875', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 690241647608795);
INSERT INTO public.transactions VALUES ('c8ebc6a9-c706-4195-9b81-2413248ca58b', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-04 11:26:49.332753', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 687042810117575);
INSERT INTO public.transactions VALUES ('ee483fe6-a4b1-4f0e-8138-f891a4cf8d4f', 100.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Deposit', 'damma4', '2025-10-04 11:31:09.781287', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 802306149223642);
INSERT INTO public.transactions VALUES ('3a0040a1-dc68-4f49-9183-cc3856faccfc', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 11:31:44.095968', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 211275806874019);
INSERT INTO public.transactions VALUES ('9dae883f-55b7-4643-9fee-98285bc587bc', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 11:31:55.64639', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 311595383848431);
INSERT INTO public.transactions VALUES ('16f7f5e3-fd6b-4ad4-8342-4fb3003392ad', 100.50, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 11:32:07.268343', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 986191972686343);
INSERT INTO public.transactions VALUES ('a29be355-36e6-44aa-90ce-8663d5accb40', 100000.50, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 11:32:21.669552', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 500650514889355);
INSERT INTO public.transactions VALUES ('bf3dea4a-0736-4b29-bf70-e8590cde0807', 100000.25, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 11:35:24.987748', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 754060340288079);
INSERT INTO public.transactions VALUES ('42968485-7c4e-44e9-90eb-2e2524e4049d', 10.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'BankTransfer-In', 'string', '2025-10-04 11:58:57.000286', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 795322413062976);
INSERT INTO public.transactions VALUES ('cb2605f7-a0b2-4c1f-88ce-bc8e7a88aaa2', 10.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'BankTransfer-Out', 'string', '2025-10-04 11:58:57.000286', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 921110500106017);
INSERT INTO public.transactions VALUES ('93c6e675-d1fd-4747-bb6d-7e74cc4f8a39', 10.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'BankTransfer-In', 'string', '2025-10-04 12:00:39.343259', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 27073176646106);
INSERT INTO public.transactions VALUES ('3f94eb1e-b5a7-42a6-bbee-4d237ea920df', 10.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'BankTransfer-Out', 'string', '2025-10-04 12:00:39.343259', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 127707374048069);
INSERT INTO public.transactions VALUES ('1f4222fc-14b9-4ec0-8584-f083b8a61010', 100000.25, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 12:13:25.511162', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 963021931708024);
INSERT INTO public.transactions VALUES ('adfc693d-7e8e-4fde-ba07-5cdef65c3606', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-04 12:13:30.364103', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 913566220312107);
INSERT INTO public.transactions VALUES ('926db7e9-ba61-4357-a743-2393b4c363b0', 10.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'BankTransfer-In', 'string', '2025-10-04 12:13:36.283783', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 717924963395123);
INSERT INTO public.transactions VALUES ('388e791c-1be8-445a-b367-8b514b012ee3', 10.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'BankTransfer-Out', 'string', '2025-10-04 12:13:36.283783', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 637806377612270);
INSERT INTO public.transactions VALUES ('9045c9d6-632b-410e-80d1-e2440b702617', 100000.25, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'damma4', '2025-10-04 13:10:41.432708', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 632304819075343);
INSERT INTO public.transactions VALUES ('e1302a6e-7323-40be-ac41-7dab6b256772', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-04 13:10:47.582915', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 903800137536799);
INSERT INTO public.transactions VALUES ('2a5bdb9a-48d4-49ea-9fde-8612be1ad263', 10.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'BankTransfer-In', 'string', '2025-10-04 13:10:53.691486', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 531032877856749);
INSERT INTO public.transactions VALUES ('ad80af1f-5cd4-46f0-a37e-b2d038f40365', 10.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'BankTransfer-Out', 'string', '2025-10-04 13:10:53.691486', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 881838457476605);
INSERT INTO public.transactions VALUES ('99f70d4e-8371-41c1-92d0-5eaee03442d2', 21.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', 'string', '2025-10-04 14:47:38.452432', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 977432922278397);
INSERT INTO public.transactions VALUES ('3e953f9a-5ba1-4035-8bc0-f7019a955fff', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'ATM withdrawal', '2025-10-05 18:14:36.451911', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 921821928857034);
INSERT INTO public.transactions VALUES ('336478e1-4c44-4a91-82d3-a9bcec406e4f', 1.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-05 18:14:43.727441', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 982010863816673);
INSERT INTO public.transactions VALUES ('76ddfeb1-d5c6-4dd9-ba7b-dd3aeeda1031', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'ATM withdrawal', '2025-10-05 18:22:28.570323', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 543411669332510);
INSERT INTO public.transactions VALUES ('32ddf007-b92a-4681-a3f9-e771408f89bf', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'ATM withdrawal', '2025-10-05 18:22:48.456817', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 815145399228117);
INSERT INTO public.transactions VALUES ('63665eee-7d7a-4a8e-807a-4228bd781e94', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'ATM withdrawal', '2025-10-05 18:24:01.048984', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 7327282619973);
INSERT INTO public.transactions VALUES ('97866d4b-b50b-4719-a4dd-2a1e16c2ca32', 100.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'ATM withdrawal', '2025-10-05 18:29:28.227393', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 811980160137042);
INSERT INTO public.transactions VALUES ('2767d787-5d1f-4a3f-a4ca-61d41fc9f88e', 1.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-05 18:29:32.860467', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 485765499510587);
INSERT INTO public.transactions VALUES ('dc821f88-b9b4-4905-99ef-4e03e86d33a0', 1.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'weithdraw money', '2025-10-05 18:30:51.690589', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 759704570835382);
INSERT INTO public.transactions VALUES ('62dee838-24b3-455a-b719-4cea4a96bacd', 50.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'cvcvc', '2025-10-05 18:54:49.926544', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 150685098622496);
INSERT INTO public.transactions VALUES ('97743ea2-91a1-42ad-b9ab-bbf7a1f01701', 588.24, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'dddd', '2025-10-05 19:14:59.313184', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 560007534755209);
INSERT INTO public.transactions VALUES ('f271ee1a-69e8-4af8-921c-5a4580265d01', 785.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'ddd', '2025-10-05 19:18:59.928445', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 671973238294429);
INSERT INTO public.transactions VALUES ('06431231-77b9-4da3-ae70-a59345101b1b', 5.90, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'd', '2025-10-05 19:30:27.56223', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 770424122292820);
INSERT INTO public.transactions VALUES ('cd425ae1-135a-446b-9829-58dfe5d18492', 12.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Withdrawal', 's', '2025-10-05 19:47:13.331218', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 292011424087881);
INSERT INTO public.transactions VALUES ('f1b1e007-4c8a-4f84-bd74-11b0e464418e', 12.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Withdrawal', 'd', '2025-10-06 17:27:42.518599', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 638771120903892);
INSERT INTO public.transactions VALUES ('44114a81-6ab7-4b9e-96dd-e1ef66ee0ee1', 12.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Withdrawal', 'x', '2025-10-06 17:28:22.231881', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 429724424428671);
INSERT INTO public.transactions VALUES ('1c797846-9c31-454d-90a3-386aad622315', 22.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Withdrawal', 'd', '2025-10-06 17:33:50.839851', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 411404275920669);
INSERT INTO public.transactions VALUES ('fc2e39f3-7160-48c3-a2ab-f61ffcf0d7b3', 22.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Withdrawal', '2', '2025-10-06 17:45:11.835223', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 168600846740115);
INSERT INTO public.transactions VALUES ('567fa701-3a41-451a-b230-6830567946ae', 12.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Withdrawal', '2', '2025-10-06 17:46:26.410894', 'de9dc531-11bf-4481-882a-dc3291580f60', 250066599180093);
INSERT INTO public.transactions VALUES ('67fb6c3b-3edb-4e7a-84e7-c13ef451d03f', 33.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Withdrawal', 'jidoalklp[ ', '2025-10-09 10:35:50.891783', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 396617152968773);
INSERT INTO public.transactions VALUES ('b723f2d7-e223-44ac-b85c-5e02b89df155', 12.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'ss', '2025-10-09 10:45:57.465252', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 293822159234248);
INSERT INTO public.transactions VALUES ('4d7972d3-31fc-4795-b42a-efec9c31303e', 100.00, 'fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'Deposit', 'damma', '2025-08-18 15:10:00.83', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 141111295237170);
INSERT INTO public.transactions VALUES ('b036ae26-ea5b-4d74-b273-e6ab8d6a5ad5', 12.00, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Withdrawal', 'd', '2025-10-14 20:57:12.45308', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 47189523895325);
INSERT INTO public.transactions VALUES ('246b2bd2-2a24-43c7-a03a-b42e78913475', 235.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'BankTransfer-Out', 'ww', '2025-10-14 20:58:01.33688', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 354814716110615);
INSERT INTO public.transactions VALUES ('a2e96290-d5ff-4734-8561-1c1640564b93', 235.00, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'BankTransfer-In', 'ww', '2025-10-14 20:58:01.33688', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 73608327561708);
INSERT INTO public.transactions VALUES ('0d47cfbf-b5fc-491f-8fad-f91f89a4478f', 1.00, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Withdrawal', 'dd', '2025-10-14 21:07:35.134167', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 756791601993193);
INSERT INTO public.transactions VALUES ('ca1d4e05-41f1-4796-b8d8-18603cbaf5ea', 100.00, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Deposit', 's', '2025-10-14 21:07:55.566951', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 312758596748702);
INSERT INTO public.transactions VALUES ('07722b14-ff2e-45ec-8ce1-862871a73626', 10.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'string', '2025-10-14 21:45:42.722073', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 760270718843290);
INSERT INTO public.transactions VALUES ('fd161bf9-7b29-46bb-b5e0-a96dccae967c', 23.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'c', '2025-10-14 21:45:46.974586', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 25450057726371);
INSERT INTO public.transactions VALUES ('2a304e96-1cdc-414d-b5ca-1aedfa9d2499', 12.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', '2x', '2025-10-14 23:55:44.34774', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 453350156797796);
INSERT INTO public.transactions VALUES ('466acbdd-4824-42ba-bebc-8c4164ce7f00', 22.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', '  c', '2025-10-15 01:02:54.445273', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 261357622103836);
INSERT INTO public.transactions VALUES ('25f84d18-0148-4548-9fdc-e19493d30574', 2.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'ded', '2025-10-15 01:17:48.314838', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 248943828434880);
INSERT INTO public.transactions VALUES ('a7d91ac3-4452-4cf2-819d-a27222d31799', 21.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-Out', '2qw', '2025-10-15 01:31:39.652166', 'de9dc531-11bf-4481-882a-dc3291580f60', 123911487323737);
INSERT INTO public.transactions VALUES ('2876c250-bf34-4f05-acbc-387de96cb920', 21.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'BankTransfer-In', '2qw', '2025-10-15 01:31:39.652166', 'de9dc531-11bf-4481-882a-dc3291580f60', 985623259359905);
INSERT INTO public.transactions VALUES ('c49e70dd-f119-4c78-a930-61a3753faba8', 233.00, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Deposit', 'fce', '2025-10-15 01:32:01.322286', 'de9dc531-11bf-4481-882a-dc3291580f60', 257206773037569);
INSERT INTO public.transactions VALUES ('2c4ad111-c7a6-4f0e-babb-1532dfe38580', 8.22, '0415f29e-fb5b-4756-baa6-bce59cab2be5', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 607821625499709);
INSERT INTO public.transactions VALUES ('db71a96b-72ae-433f-8d87-244733a304f6', 8.21, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 25574572228538);
INSERT INTO public.transactions VALUES ('fdf597a1-7a28-4e51-a934-bbcd5bfe8f0e', 0.13, '31d95fe1-7d2f-4d9e-81c1-b608131b7335', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 162720951693987);
INSERT INTO public.transactions VALUES ('d8155f10-2048-4f72-acba-780e10079687', 182.96, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 162778978175810);
INSERT INTO public.transactions VALUES ('1a2ef263-d299-4f83-a76c-51b2a3cddfb0', 3386.58, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 352891124422005);
INSERT INTO public.transactions VALUES ('0fef7229-ddea-4cd7-a90f-d465f780fbce', 0.93, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 866326270733400);
INSERT INTO public.transactions VALUES ('b38cfb19-6cc7-42de-9628-7a179069bd96', 115.07, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 431382561256298);
INSERT INTO public.transactions VALUES ('9f8e338c-7ad7-4139-812b-bd4051a7ca65', 9.86, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 279329395402897);
INSERT INTO public.transactions VALUES ('f87b8926-8697-4455-a27c-bc82e8bd2818', 2.55, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 890238746638962);
INSERT INTO public.transactions VALUES ('ffdb410c-e3f7-4479-915e-5b38b7f59c9e', 4.56, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 797137463181856);
INSERT INTO public.transactions VALUES ('25db8aa5-7e3b-44da-a356-7474c9bf48e1', 8.22, 'fb762c41-c883-4bba-9bcf-f59dfc07f042', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 473053483193324);
INSERT INTO public.transactions VALUES ('7223b5ba-7000-4bac-8f19-5c23a9629d33', 11.77, 'fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 378171184307552);
INSERT INTO public.transactions VALUES ('01b2114d-b45b-43be-b4e5-6f116893a509', 93.66, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 753956504901198);
INSERT INTO public.transactions VALUES ('34deca3c-668e-4235-8e0b-cc400585b34e', 5.75, 'fde6ebe4-72be-4574-a470-999a365b1529', 'Interest', 'Monthly interest', '2025-10-15 13:10:55.719719', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 898702337964820);
INSERT INTO public.transactions VALUES ('eb136524-5838-494c-8b57-191f5931447c', 443.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', ' vc', '2025-10-15 13:13:27.363563', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 907132512198152);
INSERT INTO public.transactions VALUES ('c01f1d42-e6a2-42cc-b716-4a445cbb64b3', 500.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', 'fef', '2025-10-15 13:14:01.56479', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 678624841694792);
INSERT INTO public.transactions VALUES ('56d20263-1b5d-43ba-8954-acf012150f5c', 1000.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-Out', 'dwds', '2025-10-15 13:15:45.521915', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 692737444470037);
INSERT INTO public.transactions VALUES ('5fa761d1-f603-46ef-8b30-a91749855132', 1000.00, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'BankTransfer-In', 'dwds', '2025-10-15 13:15:45.521915', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 603654720842696);
INSERT INTO public.transactions VALUES ('6e73c2ab-6b47-40ab-8444-51cad28105c6', 500.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'BankTransfer-Out', 'hgjh', '2025-10-15 13:16:39.488122', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 803856911053262);
INSERT INTO public.transactions VALUES ('6db1462a-5b47-411b-ba8b-1a0990611994', 500.00, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'BankTransfer-In', 'hgjh', '2025-10-15 13:16:39.488122', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 123925846936849);
INSERT INTO public.transactions VALUES ('72f01a0f-340d-4ccb-90c5-1e54271b9fab', 12.23, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'sdn', '2025-10-16 01:59:28.855252', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 441058717579701);
INSERT INTO public.transactions VALUES ('634a1ba2-2c19-4302-83e8-327dd82b63f9', 233.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'c', '2025-10-17 01:39:06.952208', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 554992337992224);
INSERT INTO public.transactions VALUES ('0e38793d-faa7-4263-946c-eefa4c252810', 187.00, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Withdrawal', 'et', '2025-10-17 01:40:16.993421', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 803790176446920);
INSERT INTO public.transactions VALUES ('2ffc9d6d-b782-44b5-b289-712e22bb3f4b', 121.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', '1', '2025-10-17 02:20:16.115744', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 308161723419069);
INSERT INTO public.transactions VALUES ('ef2a6418-8af4-4c98-bc17-ebd9240fac22', 20115.07, '8f453f53-bf51-437c-b8a9-702b08caf92d', 'Withdrawal', 'Closed the account.', '2025-10-17 09:44:56.234817', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 784646024325597);
INSERT INTO public.transactions VALUES ('a9b7f8d3-d79c-4d60-aaab-05849bb03db5', 250.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', '1', '2025-10-17 23:31:08.549325', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 299669158590103);
INSERT INTO public.transactions VALUES ('b9f78b9e-8b23-47c5-a2db-c72bcd07b9cc', 234.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'sirim', '2025-10-18 01:57:53.140759', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 666526852050219);
INSERT INTO public.transactions VALUES ('6e5bac91-5370-4134-be18-d10f5d60ddb4', 10000.00, 'fde6ebe4-72be-4574-a470-999a365b1529', 'Deposit', 'Created fixed deposit', '2025-10-20 02:56:18.352714', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 142596293120325);
INSERT INTO public.transactions VALUES ('781f2805-f0b4-4e13-b5e0-7aa1d03a69db', 10009.00, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Withdrawal', 'Fixed deposit closure for FD 92204927', '2025-10-20 03:44:11.172145', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 16083861587802);
INSERT INTO public.transactions VALUES ('3084f7c2-7c0b-4a48-96dd-a25c84ba13a0', 8.28, '1b337986-ae2d-4e9e-9f87-5bd92e29253f', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 714533049918540);
INSERT INTO public.transactions VALUES ('1e3752ce-d1ff-41f7-a0d0-dbeb61753aee', 0.13, '31d95fe1-7d2f-4d9e-81c1-b608131b7335', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 114552730038528);
INSERT INTO public.transactions VALUES ('7464fe35-0454-4404-babc-6f086e3607c0', 3410.96, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 670881030809278);
INSERT INTO public.transactions VALUES ('63f7320f-d5be-4af0-a755-9eb8c440f54e', 1094.98, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 841418125601056);
INSERT INTO public.transactions VALUES ('be47d71e-508d-4778-9eb8-3413b6dcef11', 2.57, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 422135301474055);
INSERT INTO public.transactions VALUES ('5120791f-a26e-4c88-b00d-02ce3927b614', 16.93, 'e03ca11a-ea04-4acd-9a81-66dd51d95cfa', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 783265882231012);
INSERT INTO public.transactions VALUES ('4d7f4a57-1f96-48d0-95a6-47a376584dea', 8.29, 'fb762c41-c883-4bba-9bcf-f59dfc07f042', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 457284730725935);
INSERT INTO public.transactions VALUES ('1cdc803a-b62d-43ff-b453-ad0bd1634490', 94.66, 'fd9ab8f2-ab5b-463f-93e7-0d2e1a7cd58a', 'Interest', 'Monthly interest', '2025-10-20 16:08:57.374798', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 267290039307860);
INSERT INTO public.transactions VALUES ('d5759b80-99a7-44ea-a129-5c4a046e26e5', 1035.62, 'b0134b68-04e3-4e00-a0ac-dabe67c9612f', 'Deposit', 'FD Interest - FD Account No: 92204927', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 533654220750590);
INSERT INTO public.transactions VALUES ('0b958354-6319-4729-a542-4f81a638c20d', 493.15, '58f8da96-a4c1-4071-8a8c-a195b70bb040', 'Deposit', 'FD Interest - FD Account No: 38665920', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 259537353210469);
INSERT INTO public.transactions VALUES ('6c166ecc-d640-4d4f-ba1f-640f556fe326', 961.64, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', 'FD Interest - FD Account No: 96382071', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 814257160451762);
INSERT INTO public.transactions VALUES ('f2403d3a-28c8-4be2-be14-5c2248ac352f', 575.34, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', 'FD Interest - FD Account No: 27754503', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 685641750266037);
INSERT INTO public.transactions VALUES ('fbf7d1c1-7f47-470e-ac51-15a42d425024', 1506.85, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Deposit', 'FD Interest - FD Account No: 34750437', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 991228053537734);
INSERT INTO public.transactions VALUES ('57617e33-0276-46f6-b187-427f452e438d', 986.30, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Deposit', 'FD Interest - FD Account No: 74226670', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 927541085479423);
INSERT INTO public.transactions VALUES ('f4a52ec1-0e1e-45e5-859b-23ba2fee4eb3', 61.64, '820e7b5a-8b66-4242-b7e0-a49e9880b17e', 'Deposit', 'FD Interest - FD Account No: 83370957', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 283022941876090);
INSERT INTO public.transactions VALUES ('59114317-53a7-4f0c-a906-517f8d7d22d2', 106.85, 'fde6ebe4-72be-4574-a470-999a365b1529', 'Deposit', 'FD Interest - FD Account No: 50025993', '2025-10-20 16:54:04.103615', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 934736526989167);
INSERT INTO public.transactions VALUES ('d5e54d8b-d9d5-4dad-b2e0-7e23fab4af45', 50000.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Deposit', 'Created fixed deposit', '2025-10-20 21:32:10.386211', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 364699458416091);
INSERT INTO public.transactions VALUES ('5d4be706-7e4d-433f-9f6f-9f8422878136', 5000.00, 'c1e74ae4-f466-4769-9649-f8064a7e6a89', 'Deposit', 'නිල් අහස් තලේ අගේ', '2025-10-21 10:30:24.968406', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 681862190370626);
INSERT INTO public.transactions VALUES ('ec880b88-26f7-415b-8ba0-63780e6ce34d', 15555.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Deposit', 'sfd', '2025-08-21 12:15:04.907', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 796479197476448);
INSERT INTO public.transactions VALUES ('607e19b7-02fc-4dba-95f2-7df9641c3307', 25.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', '2e3', '2025-09-21 12:17:49.288', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 644407038325979);
INSERT INTO public.transactions VALUES ('d0c61a43-d31a-44b4-97b8-f3ca2fda3c9d', 252150.00, '0415f29e-fb5b-4756-baa6-bce59cab2be5', 'Deposit', 'Created fixed deposit', '2025-10-21 17:32:04.600958', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 710224107614828);
INSERT INTO public.transactions VALUES ('7a61dc35-014e-4c7a-a591-a83112aa5874', 121.00, '3337ad45-7e90-4c8f-9057-e38f3c43f196', 'Withdrawal', 'ghjkn', '2025-10-21 17:40:31.017145', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 889047495325744);


--
-- TOC entry 3791 (class 0 OID 31107)
-- Dependencies: 239
-- Data for Name: user_login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.user_login VALUES ('9fdc2462-7532-40da-82d0-2b8a6aad1128', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'system1', '$2y$10$2tcVhTKEJ4NRts4lmw5NqOxqhCvQQ94sXMraIyK1YqWZw2Zga9vJW', '2025-09-18 06:59:15.461996', '2025-09-18 06:59:15.461996', '2025-09-18 06:59:15.461996', NULL, NULL, 'active');
INSERT INTO public.user_login VALUES ('e67ce6c6-bb0d-46cf-a222-860e548822a0', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'user3', '$2b$12$w8czX6DDYjBiJvdIjOpxVOatGl32Ca4nX40N9A2fWvsPjPTltraB6', '2025-09-18 14:04:14.712609', '2025-09-18 14:04:14.712609', '2025-09-18 14:04:14.712609', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active');
INSERT INTO public.user_login VALUES ('86295c07-2139-4499-9410-d729b012cfb7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'user4', '$2b$12$K4ZpGK2cPR0kivNqhtVRzO6vkOSkFKOkx/zNiAKuREJEqVu.BQ.y2', '2025-09-18 14:18:45.238594', '2025-09-18 14:18:45.238594', '2025-09-18 14:18:45.238594', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'active');
INSERT INTO public.user_login VALUES ('e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd', 'de9dc531-11bf-4481-882a-dc3291580f60', 'user1', '$2b$12$14vPB5UI74Cs/6gIah46wecLcncl4.0qcBQ9XqtXLkFvYj9e5qYIC', '2025-09-18 07:09:21.535303', '2025-09-18 07:09:21.535303', '2025-10-17 21:28:05.066993', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'active');
INSERT INTO public.user_login VALUES ('8e940780-67c7-42e8-a307-4a92664ab72f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'user2', '$2b$12$3AyYkBrss9CGMdyBRQyT0eTKkQDu.f0C0nJeg.DLmDO09ORx77o6K', '2025-09-18 07:19:23.418837', '2025-09-18 07:19:23.418837', '2025-10-20 17:18:34.077441', 'de9dc531-11bf-4481-882a-dc3291580f60', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'active');


--
-- TOC entry 3792 (class 0 OID 31117)
-- Dependencies: 240
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


--
-- TOC entry 3793 (class 0 OID 31126)
-- Dependencies: 241
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users VALUES ('839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', NULL, 'System ', 'main', NULL, NULL, NULL, '2025-09-18 06:57:17.48252', '2025-10-15 14:36:18.463189', NULL, NULL, 'salmal@gmail.com');
INSERT INTO public.users VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '200325314526', 'user1', 'user1', 'user 1  address', '0765898755', '2003-01-01', '2025-09-18 07:09:21.535303', '2025-10-15 14:36:18.464718', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'ns@gmail.com');
INSERT INTO public.users VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '200135645879', 'user3', 'user3', 'jafna', '045789866', '2004-10-10', '2025-09-18 14:04:14.712609', '2025-10-15 14:36:18.466528', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'sapumal@gmail.com');
INSERT INTO public.users VALUES ('75cf1bda-3240-41c5-8235-5a0f06d51fa7', '200135645870', 'user4', 'user4', 'jafna', '045789866', '2004-10-10', '2025-09-18 14:18:45.238594', '2025-10-15 14:36:18.46739', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'Sunimal@gmail.com');
INSERT INTO public.users VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '200325314527', 'Maneesha ', 'Herath', 'user 2  address', '0765898745', '2003-01-01', '2025-09-18 07:19:23.418837', '2025-10-20 17:18:01.413139', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60', 'cse23@gmail.co');


--
-- TOC entry 3794 (class 0 OID 31132)
-- Dependencies: 242
-- Data for Name: users_branch; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users_branch VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '57438d7f-184f-42fe-b0d6-91a2ef609beb');
INSERT INTO public.users_branch VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3dd6870c-e6f2-414d-9973-309ba00ce115');


--
-- TOC entry 3795 (class 0 OID 31135)
-- Dependencies: 243
-- Data for Name: users_role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users_role VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '88e07160-2df2-4d18-ab38-9b4668267956');
INSERT INTO public.users_role VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '05865b54-4591-4ccb-b1b8-bacf4c8771a2');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '34dbe9a4-95a3-4abb-9442-5a78ea632af9');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '5d8461b9-9f7d-4c8e-8306-91760ef30a9b');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '05865b54-4591-4ccb-b1b8-bacf4c8771a2');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b116c56-efe7-45eb-883b-b3e7d5f68145');


--
-- TOC entry 3804 (class 0 OID 0)
-- Dependencies: 244
-- Name: jobid_seq; Type: SEQUENCE SET; Schema: cron; Owner: -
--

SELECT pg_catalog.setval('cron.jobid_seq', 6, true);


--
-- TOC entry 3805 (class 0 OID 0)
-- Dependencies: 246
-- Name: runid_seq; Type: SEQUENCE SET; Schema: cron; Owner: -
--

SELECT pg_catalog.setval('cron.runid_seq', 1, false);


--
-- TOC entry 3507 (class 2606 OID 31139)
-- Name: account account_account_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_account_no_key UNIQUE (account_no);


--
-- TOC entry 3509 (class 2606 OID 31141)
-- Name: account account_no_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_no_unique UNIQUE (account_no);


--
-- TOC entry 3511 (class 2606 OID 31143)
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (acc_id);


--
-- TOC entry 3515 (class 2606 OID 31145)
-- Name: accounts_owner accounts_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_pkey PRIMARY KEY (acc_id, customer_id);


--
-- TOC entry 3517 (class 2606 OID 31147)
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id);


--
-- TOC entry 3522 (class 2606 OID 31149)
-- Name: branch branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_pkey PRIMARY KEY (branch_id);


--
-- TOC entry 3530 (class 2606 OID 31151)
-- Name: customer_login customer_login_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_key UNIQUE (customer_id);


--
-- TOC entry 3532 (class 2606 OID 31153)
-- Name: customer_login customer_login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3534 (class 2606 OID 31155)
-- Name: customer_login customer_login_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_username_key UNIQUE (username);


--
-- TOC entry 3524 (class 2606 OID 31468)
-- Name: customer customer_nic_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_nic_key UNIQUE (nic);


--
-- TOC entry 3526 (class 2606 OID 31159)
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- TOC entry 3536 (class 2606 OID 31161)
-- Name: fd_plan fd_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_pkey PRIMARY KEY (fd_plan_id);


--
-- TOC entry 3538 (class 2606 OID 31163)
-- Name: fixed_deposit fixed_deposit_fd_account_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_fd_account_no_key UNIQUE (fd_account_no);


--
-- TOC entry 3540 (class 2606 OID 31165)
-- Name: fixed_deposit fixed_deposit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_pkey PRIMARY KEY (fd_id);


--
-- TOC entry 3544 (class 2606 OID 31167)
-- Name: login login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_pkey PRIMARY KEY (log_id);


--
-- TOC entry 3546 (class 2606 OID 31169)
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (role_id);


--
-- TOC entry 3548 (class 2606 OID 31171)
-- Name: role role_role_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_role_name_key UNIQUE (role_name);


--
-- TOC entry 3550 (class 2606 OID 31173)
-- Name: savings_plan savings_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_pkey PRIMARY KEY (savings_plan_id);


--
-- TOC entry 3555 (class 2606 OID 31175)
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (transaction_id);


--
-- TOC entry 3557 (class 2606 OID 31177)
-- Name: transactions transactions_reference_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_reference_no_key UNIQUE (reference_no);


--
-- TOC entry 3559 (class 2606 OID 31179)
-- Name: user_login user_login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3561 (class 2606 OID 31181)
-- Name: user_login user_login_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_key UNIQUE (user_id);


--
-- TOC entry 3563 (class 2606 OID 31183)
-- Name: user_login user_login_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_username_key UNIQUE (username);


--
-- TOC entry 3569 (class 2606 OID 31185)
-- Name: user_refresh_tokens user_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_pkey PRIMARY KEY (token_id);


--
-- TOC entry 3577 (class 2606 OID 31187)
-- Name: users_branch users_branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_pkey PRIMARY KEY (user_id, branch_id);


--
-- TOC entry 3573 (class 2606 OID 31189)
-- Name: users users_nic_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_nic_key UNIQUE (nic);


--
-- TOC entry 3575 (class 2606 OID 31191)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- TOC entry 3579 (class 2606 OID 31193)
-- Name: users_role users_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_pkey PRIMARY KEY (user_id, role_id);


--
-- TOC entry 3512 (class 1259 OID 31194)
-- Name: idx_account_account_no; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_account_no ON public.account USING btree (account_no);


--
-- TOC entry 3513 (class 1259 OID 31195)
-- Name: idx_account_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_branch_id ON public.account USING btree (branch_id);


--
-- TOC entry 3518 (class 1259 OID 31196)
-- Name: idx_audit_log_table_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_table_record ON public.audit_log USING btree (table_name, record_id);


--
-- TOC entry 3519 (class 1259 OID 31197)
-- Name: idx_audit_log_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_timestamp ON public.audit_log USING btree ("timestamp");


--
-- TOC entry 3520 (class 1259 OID 31198)
-- Name: idx_audit_log_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_user_id ON public.audit_log USING btree (user_id);


--
-- TOC entry 3527 (class 1259 OID 31199)
-- Name: idx_customer_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_created_at ON public.customer USING btree (created_at);


--
-- TOC entry 3528 (class 1259 OID 31469)
-- Name: idx_customer_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_nic ON public.customer USING btree (nic);


--
-- TOC entry 3541 (class 1259 OID 31201)
-- Name: idx_login_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_time ON public.login USING btree (login_time);


--
-- TOC entry 3542 (class 1259 OID 31202)
-- Name: idx_login_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_user_id ON public.login USING btree (user_id);


--
-- TOC entry 3551 (class 1259 OID 31203)
-- Name: idx_transactions_acc_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_acc_id ON public.transactions USING btree (acc_id);


--
-- TOC entry 3552 (class 1259 OID 31204)
-- Name: idx_transactions_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at);


--
-- TOC entry 3553 (class 1259 OID 31205)
-- Name: idx_transactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_type ON public.transactions USING btree (type);


--
-- TOC entry 3564 (class 1259 OID 31206)
-- Name: idx_user_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_expires_at ON public.user_refresh_tokens USING btree (expires_at);


--
-- TOC entry 3565 (class 1259 OID 31207)
-- Name: idx_user_refresh_tokens_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_hash ON public.user_refresh_tokens USING btree (token_hash);


--
-- TOC entry 3566 (class 1259 OID 31208)
-- Name: idx_user_refresh_tokens_revoked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_revoked ON public.user_refresh_tokens USING btree (is_revoked);


--
-- TOC entry 3567 (class 1259 OID 31209)
-- Name: idx_user_refresh_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_user_id ON public.user_refresh_tokens USING btree (user_id);


--
-- TOC entry 3570 (class 1259 OID 31210)
-- Name: idx_users_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_created_at ON public.users USING btree (created_at);


--
-- TOC entry 3571 (class 1259 OID 31211)
-- Name: idx_users_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_nic ON public.users USING btree (nic);


--
-- TOC entry 3622 (class 2620 OID 31212)
-- Name: account update_account_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_account_updated_at BEFORE UPDATE ON public.account FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3623 (class 2620 OID 31213)
-- Name: branch update_branch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_branch_updated_at BEFORE UPDATE ON public.branch FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3625 (class 2620 OID 31214)
-- Name: customer_login update_customer_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_login_updated_at BEFORE UPDATE ON public.customer_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3624 (class 2620 OID 31215)
-- Name: customer update_customer_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_updated_at BEFORE UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3626 (class 2620 OID 31216)
-- Name: fd_plan update_fd_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fd_plan_updated_at BEFORE UPDATE ON public.fd_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3627 (class 2620 OID 31217)
-- Name: fixed_deposit update_fixed_deposit_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fixed_deposit_updated_at BEFORE UPDATE ON public.fixed_deposit FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3628 (class 2620 OID 31218)
-- Name: savings_plan update_savings_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_savings_plan_updated_at BEFORE UPDATE ON public.savings_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3629 (class 2620 OID 31219)
-- Name: user_login update_user_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_login_updated_at BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3631 (class 2620 OID 31220)
-- Name: user_refresh_tokens update_user_refresh_tokens_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_refresh_tokens_updated_at BEFORE UPDATE ON public.user_refresh_tokens FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3632 (class 2620 OID 31221)
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3630 (class 2620 OID 31222)
-- Name: user_login user_login_update_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_login_update_audit BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.audit_user_login_update();


--
-- TOC entry 3586 (class 2606 OID 31223)
-- Name: account account_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3587 (class 2606 OID 31228)
-- Name: account account_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3588 (class 2606 OID 31233)
-- Name: account account_savings_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_savings_plan_id_fkey FOREIGN KEY (savings_plan_id) REFERENCES public.savings_plan(savings_plan_id);


--
-- TOC entry 3589 (class 2606 OID 31238)
-- Name: account account_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3590 (class 2606 OID 31243)
-- Name: accounts_owner accounts_owner_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3591 (class 2606 OID 31248)
-- Name: accounts_owner accounts_owner_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- TOC entry 3592 (class 2606 OID 31253)
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3593 (class 2606 OID 31258)
-- Name: branch branch_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3594 (class 2606 OID 31263)
-- Name: branch branch_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3595 (class 2606 OID 31268)
-- Name: customer customer_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3597 (class 2606 OID 31273)
-- Name: customer_login customer_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3598 (class 2606 OID 31278)
-- Name: customer_login customer_login_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON DELETE CASCADE;


--
-- TOC entry 3599 (class 2606 OID 31283)
-- Name: customer_login customer_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3596 (class 2606 OID 31288)
-- Name: customer customer_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3600 (class 2606 OID 31293)
-- Name: fd_plan fd_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3601 (class 2606 OID 31298)
-- Name: fd_plan fd_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3602 (class 2606 OID 31303)
-- Name: fixed_deposit fixed_deposit_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3603 (class 2606 OID 31308)
-- Name: fixed_deposit fixed_deposit_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3604 (class 2606 OID 31313)
-- Name: fixed_deposit fixed_deposit_fd_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_fd_plan_id_fkey FOREIGN KEY (fd_plan_id) REFERENCES public.fd_plan(fd_plan_id);


--
-- TOC entry 3605 (class 2606 OID 31318)
-- Name: fixed_deposit fixed_deposit_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3606 (class 2606 OID 31323)
-- Name: login login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3607 (class 2606 OID 31328)
-- Name: savings_plan savings_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3608 (class 2606 OID 31333)
-- Name: savings_plan savings_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3609 (class 2606 OID 31338)
-- Name: transactions transactions_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3610 (class 2606 OID 31343)
-- Name: transactions transactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3611 (class 2606 OID 31348)
-- Name: user_login user_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3612 (class 2606 OID 31353)
-- Name: user_login user_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3613 (class 2606 OID 31358)
-- Name: user_login user_login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- TOC entry 3614 (class 2606 OID 31363)
-- Name: user_refresh_tokens user_refresh_tokens_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES public.users(user_id);


--
-- TOC entry 3615 (class 2606 OID 31368)
-- Name: user_refresh_tokens user_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3618 (class 2606 OID 31373)
-- Name: users_branch users_branch_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3619 (class 2606 OID 31378)
-- Name: users_branch users_branch_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3616 (class 2606 OID 31383)
-- Name: users users_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3620 (class 2606 OID 31388)
-- Name: users_role users_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(role_id);


--
-- TOC entry 3621 (class 2606 OID 31393)
-- Name: users_role users_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3617 (class 2606 OID 31398)
-- Name: users users_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


-- Completed on 2025-10-21 18:43:47 +0530

--
-- PostgreSQL database dump complete
--


