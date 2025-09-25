--
-- PostgreSQL database dump
--

-- Dumped from database version 17.5
-- Dumped by pg_dump version 17.5

-- Started on 2025-09-24 19:47:46 +0530

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
-- TOC entry 3723 (class 1262 OID 17772)
-- Name: bankdata; Type: DATABASE; Schema: -; Owner: microbank
--



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
-- TOC entry 6 (class 2615 OID 25565)
-- Name: public; Type: SCHEMA; Schema: -; Owner: postgres
--

-- *not* creating schema, since initdb creates it


--
-- TOC entry 3724 (class 0 OID 0)
-- Dependencies: 6
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA public IS '';


--
-- TOC entry 2 (class 3079 OID 25566)
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- TOC entry 3726 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- TOC entry 964 (class 1247 OID 26852)
-- Name: account_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.account_status AS ENUM (
    'active',
    'frozen',
    'closed'
);


ALTER TYPE public.account_status OWNER TO postgres;

--
-- TOC entry 955 (class 1247 OID 25912)
-- Name: audit_action; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.audit_action AS ENUM (
    'INSERT',
    'UPDATE',
    'DELETE'
);


ALTER TYPE public.audit_action OWNER TO postgres;

--
-- TOC entry 931 (class 1247 OID 25780)
-- Name: transaction_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.transaction_type AS ENUM (
    'Deposit',
    'Withdrawal',
    'Interest',
    'BankTransfer'
);


ALTER TYPE public.transaction_type OWNER TO postgres;

--
-- TOC entry 236 (class 1255 OID 26833)
-- Name: audit_user_login_update(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.audit_user_login_update() OWNER TO postgres;

--
-- TOC entry 288 (class 1255 OID 25954)
-- Name: cleanup_expired_user_refresh_tokens(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.cleanup_expired_user_refresh_tokens() OWNER TO postgres;

--
-- TOC entry 251 (class 1255 OID 26881)
-- Name: create_account_for_existing_customer_by_nic(character varying, uuid, uuid, uuid, numeric, public.account_status); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.create_account_for_existing_customer_by_nic(p_nic character varying, p_branch_id uuid, p_savings_plan_id uuid, p_created_by_user_id uuid, p_balance numeric, p_status public.account_status) OWNER TO postgres;

--
-- TOC entry 250 (class 1255 OID 26875)
-- Name: create_customer_with_login(text, text, text, text, date, text, text, uuid, uuid, numeric, uuid, public.account_status); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.create_customer_with_login(p_full_name text, p_address text, p_phone_number text, p_nic text, p_dob date, p_username text, p_password text, p_branch_id uuid, p_savings_plan_id uuid, p_balance numeric, p_created_by uuid, p_status public.account_status) OWNER TO postgres;

--
-- TOC entry 235 (class 1255 OID 25987)
-- Name: create_initial_user(character varying, character varying, character varying, character varying, character varying, date, character varying, text); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.create_initial_user(p_nic character varying, p_first_name character varying, p_last_name character varying, p_address character varying, p_phone_number character varying, p_dob date, p_username character varying, p_password_hash text) OWNER TO postgres;

--
-- TOC entry 248 (class 1255 OID 26831)
-- Name: create_user(character varying, character varying, character varying, character varying, character varying, date, character varying, character varying, uuid); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.create_user(p_nic character varying, p_first_name character varying, p_last_name character varying, p_address character varying, p_phone_number character varying, p_dob date, p_username character varying, p_hashed_password character varying, p_created_by uuid) OWNER TO postgres;

--
-- TOC entry 249 (class 1255 OID 26832)
-- Name: create_user(character varying, character varying, character varying, character varying, character varying, date, character varying, character varying, uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.create_user(p_nic character varying, p_first_name character varying, p_last_name character varying, p_address character varying, p_phone_number character varying, p_dob date, p_username character varying, p_hashed_password character varying, p_created_by uuid, p_updated_by uuid) OWNER TO postgres;

--
-- TOC entry 289 (class 1255 OID 25955)
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 224 (class 1259 OID 25719)
-- Name: account; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.account OWNER TO postgres;

--
-- TOC entry 232 (class 1259 OID 25896)
-- Name: accounts_owner; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accounts_owner (
    acc_id uuid NOT NULL,
    customer_id uuid NOT NULL
);


ALTER TABLE public.accounts_owner OWNER TO postgres;

--
-- TOC entry 233 (class 1259 OID 25919)
-- Name: audit_log; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.audit_log OWNER TO postgres;

--
-- TOC entry 221 (class 1259 OID 25665)
-- Name: branch; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.branch OWNER TO postgres;

--
-- TOC entry 229 (class 1259 OID 25831)
-- Name: customer; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customer (
    customer_id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name character varying(150) NOT NULL,
    address character varying(255),
    phone_number character varying(15),
    nic character varying(12),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid,
    dob date NOT NULL
);


ALTER TABLE public.customer OWNER TO postgres;

--
-- TOC entry 230 (class 1259 OID 25851)
-- Name: customer_login; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.customer_login OWNER TO postgres;

--
-- TOC entry 222 (class 1259 OID 25683)
-- Name: fd_plan; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.fd_plan (
    fd_plan_id uuid DEFAULT gen_random_uuid() NOT NULL,
    duration integer,
    interest_rate numeric(5,2),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid
);


ALTER TABLE public.fd_plan OWNER TO postgres;

--
-- TOC entry 225 (class 1259 OID 25750)
-- Name: fixed_deposit; Type: TABLE; Schema: public; Owner: postgres
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
    updated_by uuid
);


ALTER TABLE public.fixed_deposit OWNER TO postgres;

--
-- TOC entry 220 (class 1259 OID 25653)
-- Name: login; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.login (
    log_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    login_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.login OWNER TO postgres;

--
-- TOC entry 227 (class 1259 OID 25808)
-- Name: role; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.role (
    role_id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_name character varying(50) NOT NULL
);


ALTER TABLE public.role OWNER TO postgres;

--
-- TOC entry 223 (class 1259 OID 25701)
-- Name: savings_plan; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.savings_plan (
    savings_plan_id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_name character varying(100),
    interest_rate numeric(5,2),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid
);


ALTER TABLE public.savings_plan OWNER TO postgres;

--
-- TOC entry 226 (class 1259 OID 25789)
-- Name: transactions; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.transactions OWNER TO postgres;

--
-- TOC entry 219 (class 1259 OID 25623)
-- Name: user_login; Type: TABLE; Schema: public; Owner: postgres
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
    updated_by uuid
);


ALTER TABLE public.user_login OWNER TO postgres;

--
-- TOC entry 234 (class 1259 OID 25933)
-- Name: user_refresh_tokens; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.user_refresh_tokens OWNER TO postgres;

--
-- TOC entry 218 (class 1259 OID 25603)
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.users OWNER TO postgres;

--
-- TOC entry 231 (class 1259 OID 25881)
-- Name: users_branch; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users_branch (
    user_id uuid NOT NULL,
    branch_id uuid NOT NULL
);


ALTER TABLE public.users_branch OWNER TO postgres;

--
-- TOC entry 228 (class 1259 OID 25816)
-- Name: users_role; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users_role (
    user_id uuid NOT NULL,
    role_id uuid NOT NULL
);


ALTER TABLE public.users_role OWNER TO postgres;

--
-- TOC entry 3707 (class 0 OID 25719)
-- Dependencies: 224
-- Data for Name: account; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.account (acc_id, account_no, branch_id, savings_plan_id, balance, opened_date, created_at, updated_at, created_by, updated_by, status) FROM stdin;
1b337986-ae2d-4e9e-9f87-5bd92e29253f	1234567890	3dd6870c-e6f2-414d-9973-309ba00ce115	3578bd55-8c57-4757-aa7b-0f37b859edd6	1000.000000000000	2025-09-18 13:56:05.448161	2025-09-18 13:56:05.448161	2025-09-18 14:07:15.810099	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	active
fb7b432f-634b-4b7c-9ee5-f4ba4a38f531	123456789	57438d7f-184f-42fe-b0d6-91a2ef609beb	7d8f328d-650d-4e19-b2ef-4c7292f6264a	2000.000000000000	2025-09-18 14:07:15.807623	2025-09-18 14:07:15.807623	2025-09-18 14:26:16.479309	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	active
3337ad45-7e90-4c8f-9057-e38f3c43f196	1111111111	3dd6870c-e6f2-414d-9973-309ba00ce115	3578bd55-8c57-4757-aa7b-0f37b859edd6	3000.000000000000	2025-09-18 14:43:34.844831	2025-09-18 14:43:34.844831	2025-09-18 14:43:34.844831	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	active
c1e74ae4-f466-4769-9649-f8064a7e6a89	6052845866	3dd6870c-e6f2-414d-9973-309ba00ce115	3578bd55-8c57-4757-aa7b-0f37b859edd6	105.000000000000	2025-09-24 14:56:44.494199	2025-09-24 14:56:44.494199	2025-09-24 14:56:44.494199	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	active
58f8da96-a4c1-4071-8a8c-a195b70bb040	2815823974	3dd6870c-e6f2-414d-9973-309ba00ce115	3578bd55-8c57-4757-aa7b-0f37b859edd6	101.000000000000	2025-09-24 17:50:34.479023	2025-09-24 17:50:34.479023	2025-09-24 17:50:34.479023	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	active
e03ca11a-ea04-4acd-9a81-66dd51d95cfa	8120354779	3dd6870c-e6f2-414d-9973-309ba00ce115	3578bd55-8c57-4757-aa7b-0f37b859edd6	310.000000000000	2025-09-24 19:39:23.999379	2025-09-24 19:39:23.999379	2025-09-24 19:39:23.999379	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	active
\.


--
-- TOC entry 3715 (class 0 OID 25896)
-- Dependencies: 232
-- Data for Name: accounts_owner; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.accounts_owner (acc_id, customer_id) FROM stdin;
1b337986-ae2d-4e9e-9f87-5bd92e29253f	12d17661-847d-4385-9fd2-ea582da813b2
fb7b432f-634b-4b7c-9ee5-f4ba4a38f531	96a6ea17-b2d3-40d0-9c5b-903da6280f50
fb7b432f-634b-4b7c-9ee5-f4ba4a38f531	f0bf0ef8-0015-4c79-bae4-bab26d897409
3337ad45-7e90-4c8f-9057-e38f3c43f196	97da5431-f39a-43e5-b0cd-9d185327b6e6
c1e74ae4-f466-4769-9649-f8064a7e6a89	12d17661-847d-4385-9fd2-ea582da813b2
58f8da96-a4c1-4071-8a8c-a195b70bb040	8f99e4a7-47ed-44ea-947f-89dae567a52c
e03ca11a-ea04-4acd-9a81-66dd51d95cfa	8f99e4a7-47ed-44ea-947f-89dae567a52c
\.


--
-- TOC entry 3716 (class 0 OID 25919)
-- Dependencies: 233
-- Data for Name: audit_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.audit_log (audit_id, table_name, record_id, action, old_values, changed_fields, user_id, "timestamp") FROM stdin;
e725be3d-ade7-4881-ab46-2dceae2bdad8	users	de9dc531-11bf-4481-882a-dc3291580f60	INSERT	\N	{nic,first_name,last_name,address,phone_number,dob,created_by}	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	2025-09-18 07:09:21.535303
cd24de61-14f1-4914-a477-51dcfd564c21	users	6b997217-9ce5-4dda-a9ae-87bf589b92a5	INSERT	\N	{nic,first_name,last_name,address,phone_number,dob,created_by}	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-18 07:19:23.418837
b85bcf9b-0083-4f87-b74d-f436f210439a	users	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	INSERT	\N	{nic,first_name,last_name,address,phone_number,dob,created_by}	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-18 14:04:14.712609
2469da8a-bac2-4709-9294-cbc8a8f6426c	users	75cf1bda-3240-41c5-8235-5a0f06d51fa7	INSERT	\N	{nic,first_name,last_name,address,phone_number,dob,created_by}	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-18 14:18:45.238594
\.


--
-- TOC entry 3704 (class 0 OID 25665)
-- Dependencies: 221
-- Data for Name: branch; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.branch (branch_id, name, address, created_at, updated_at, created_by, updated_by) FROM stdin;
3dd6870c-e6f2-414d-9973-309ba00ce115	Colombo	colombo	2025-09-18 07:05:43.839001	2025-09-18 07:05:43.839001	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1
57438d7f-184f-42fe-b0d6-91a2ef609beb	Jafna	Jafna	2025-09-18 07:07:02.375386	2025-09-18 07:07:02.375386	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1
\.


--
-- TOC entry 3712 (class 0 OID 25831)
-- Dependencies: 229
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (customer_id, full_name, address, phone_number, nic, created_at, updated_at, created_by, updated_by, dob) FROM stdin;
12d17661-847d-4385-9fd2-ea582da813b2	customer 3	colombo	0745879866	200147897589	2025-09-18 14:33:26.650656	2025-09-18 14:33:26.650656	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2001-02-06
96a6ea17-b2d3-40d0-9c5b-903da6280f50	customer 1	jafna	0724548799	200454546545	2025-09-18 14:29:18.039149	2025-09-18 14:33:26.652769	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	2001-02-06
f0bf0ef8-0015-4c79-bae4-bab26d897409	customer 2	jafna	0756548799	200725457898	2025-09-18 14:29:55.137535	2025-09-18 14:33:26.654507	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	2001-02-06
97da5431-f39a-43e5-b0cd-9d185327b6e6	customer 4	colombo	0144545466	211454546587	2025-09-18 14:41:28.403699	2025-09-18 14:41:28.403699	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2001-02-06
8f99e4a7-47ed-44ea-947f-89dae567a52c	customer7	string	string	string	2025-09-24 17:50:34.479023	2025-09-24 17:50:34.479023	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2001-11-11
\.


--
-- TOC entry 3713 (class 0 OID 25851)
-- Dependencies: 230
-- Data for Name: customer_login; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer_login (login_id, customer_id, username, password, password_last_update, created_at, updated_at, created_by, updated_by) FROM stdin;
657f315a-9b6a-4c54-a3d1-b72fa645c7f5	97da5431-f39a-43e5-b0cd-9d185327b6e6	mycustomer	$2a$12$7gXkpFQmcoCPFx39ssSJb.FcJNK8opQzlLU5z5XcoYJEpcKZjWthm	2025-09-19 02:18:40.386038	2025-09-19 02:18:40.386038	2025-09-19 02:18:40.386038	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5
bf23810f-9d8e-411a-b7f8-661766306774	8f99e4a7-47ed-44ea-947f-89dae567a52c	customer70757	Bs3ewE5Q	2025-09-24 17:50:34.479023	2025-09-24 17:50:34.479023	2025-09-24 17:50:34.479023	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5
\.


--
-- TOC entry 3705 (class 0 OID 25683)
-- Dependencies: 222
-- Data for Name: fd_plan; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.fd_plan (fd_plan_id, duration, interest_rate, created_at, updated_at, created_by, updated_by) FROM stdin;
aba51ea9-6174-4a6e-8463-6d03dd717185	6	13.00	2025-09-18 13:37:13.902794	2025-09-18 13:37:13.902794	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
f6248a43-7311-4741-bf69-9e3628df3cee	12	14.00	2025-09-18 13:37:13.906323	2025-09-18 13:37:13.906323	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
fede8a9f-d3a5-4aee-a763-e43eae84397f	36	15.00	2025-09-18 13:37:13.907726	2025-09-18 13:37:13.907726	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
\.


--
-- TOC entry 3708 (class 0 OID 25750)
-- Dependencies: 225
-- Data for Name: fixed_deposit; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.fixed_deposit (fd_id, balance, acc_id, opened_date, maturity_date, fd_plan_id, created_at, updated_at, created_by, updated_by) FROM stdin;
11b6d2ad-ce98-48e2-a70f-0660d84247d0	20000.000000000000	3337ad45-7e90-4c8f-9057-e38f3c43f196	2025-09-18 15:06:34.963377	2026-03-18 15:06:34.963	aba51ea9-6174-4a6e-8463-6d03dd717185	2025-09-18 15:06:34.963377	2025-09-18 15:07:06.178408	6b997217-9ce5-4dda-a9ae-87bf589b92a5	6b997217-9ce5-4dda-a9ae-87bf589b92a5
\.


--
-- TOC entry 3703 (class 0 OID 25653)
-- Dependencies: 220
-- Data for Name: login; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.login (log_id, user_id, login_time) FROM stdin;
ef0de396-9787-4c94-81b4-14b1e087fb51	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	2025-09-18 07:01:09.926708
97ac0c3a-f003-4f92-bae1-edce2a4b7406	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-18 07:18:25.922307
7f26152e-ee50-4ea2-add4-5042e703a9f3	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-18 14:02:15.673806
c7a75b83-7373-4eab-940d-ef69e5ed44e2	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 00:12:51.793619
24cd39be-cecf-48bb-99c5-fb23ce166393	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 00:13:31.50498
956aaf49-ae2a-4947-8240-b76fc1485a9a	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 00:19:04.878591
a00747be-3c10-495b-b5e2-62ffcd65cd69	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 00:21:39.068569
088d8aab-4a05-46bb-a680-427742fac103	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 08:29:33.647934
d8704f1d-c2b9-4bf3-bfd3-e5e7c6324fa7	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 08:36:07.238748
661ac81f-7f8d-4391-8e5a-53ef9f88be78	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 08:38:45.676682
98f5e1fc-685d-4d91-a2a7-639618287f22	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 08:38:45.830166
08081e37-51c7-4b7b-abc3-fa770d7f0fac	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:12:44.162598
8b4f58a9-4aa7-49bb-a323-da66ae8e9a8c	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:15:19.051326
4ddb70fe-01ab-4de1-9496-0ff91a87cf3c	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:26:09.18484
da1843dc-2286-4468-a6f7-9ac3a618a47f	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:28:10.791807
798891a8-e72c-4331-a8d6-99b6107aafbe	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:28:51.849261
86a8e9d8-d08e-4be1-b992-4af061423aa2	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:30:11.104932
f91d0d08-2116-4d84-b710-32d2011b0115	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:30:18.18191
0af891cb-de3d-4748-aeda-449e0dc84902	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:33:49.144016
66eaf027-57a9-4a88-b9fc-a5a27ccd1e96	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:34:04.460221
e404055a-44ff-4f4c-87ea-bb4e968741ca	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:34:30.289995
0566b1e1-9e1f-4f6f-a3f2-d4a0d7dbc1b6	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:39:29.91845
c0b72674-98d4-4e46-867f-a0123fc78c6e	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:40:00.31766
5c2da375-a53e-4de7-b2e1-efb7c828370f	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:41:12.982784
222ca744-5236-4286-8dd3-e4b4483a0b05	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:41:26.518716
25f7bc81-b06f-4a98-9275-0d884513e704	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 09:43:22.662356
ee36c8d4-e24d-403f-a07e-5bb803939f34	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:14:56.642084
332f9250-1352-430d-9859-6b6c6e76872f	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:15:16.806745
104dc9f0-339c-4901-b0bd-2149ad5b5305	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:18:53.236694
019fb882-1814-4f74-8627-0a2baf5fceaa	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:20:50.930569
a7a73d01-fce9-4950-b21d-9b90cbdf41ab	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:21:08.494516
851db057-88fd-4022-bfe3-5004634b6e31	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:24:36.974369
21ca13ef-808c-4083-8338-e66a9aa84662	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 10:24:37.119049
247e66d9-579b-495a-b8a3-9ee7e08ed9d4	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 11:58:36.805702
43d8f319-0a0e-4141-9846-558f41d7ca9e	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:32:14.457167
be85ca9c-0233-46ed-9df5-1a4dbdc6765b	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:42:22.106468
239cde64-84c9-46af-9129-c235d8983b79	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:45:53.248993
f0505621-71d7-4471-bed2-723ffaf635b5	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:51:19.637397
0617d2e6-1141-4e66-967c-e4fe6f6bba68	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:52:08.664102
053b92c7-470a-4994-8e92-a42a441a752b	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:54:08.894736
227bd0d4-2529-4a9f-8f54-4aa3f1698f67	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 12:55:40.120396
52dd694a-bed1-4043-b29a-22d7f016a77d	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 13:21:08.872421
7178ca92-9a44-4174-a701-0a17139d22fa	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 14:55:55.070887
0f754dc9-5060-489f-a928-42c4cd36f21d	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 15:02:07.285389
b4b9a587-da46-452f-bf9a-94a93df86285	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 15:02:34.493569
916333ac-8e5d-4f42-811a-ce5b5a95231c	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-22 15:04:55.165556
9b6a88bd-8e32-47d0-8c47-1a5f024fc1e2	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:05:23.591901
0bdf145d-014b-402d-9bbc-298d2530df75	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:08:08.734019
f0b725c9-12a6-473c-8aae-5ea3c8291dd3	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:15:51.918282
400d52ba-8f6b-4183-9411-adaddf8f7ceb	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:25:24.529113
8544fc12-c262-427b-ae83-b813268dc5ae	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:29:03.255206
295fb3ef-1c47-4efb-a9bd-bba3c8116a8d	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:30:35.183195
c2abbfa0-29d3-4b46-9d77-398f3ac769b0	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:31:04.780978
75426396-5a2e-4840-a21d-d38138a1ce3c	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:34:51.942397
1c30921d-471c-4cd8-a62a-d646eaa03e5d	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:39:28.159649
6d88e1e9-32b5-402b-839f-090fc79e78d3	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:48:10.59552
e5b97c88-c51a-4125-b385-090fa9337142	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 16:53:14.776179
40f6041c-2230-4496-8762-ed503ac08c1a	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 18:22:57.789061
44c92e5a-dfc7-43b4-9177-f95ae6ce7116	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 18:27:18.47859
130244f1-0789-4005-a18a-4aa242ec470e	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 18:58:43.309883
0f71786b-635b-4f3d-b286-a531b2f46d7c	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 19:03:40.990556
3f7ccca4-43f6-45c7-aeeb-31d7dfe7b0ea	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 19:06:33.792775
12d5fba8-fc25-4a8f-a072-dcdb89f0c245	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 19:09:20.209367
11c0f672-6c5e-4c53-8bc0-ece376e83bce	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-23 19:18:56.242158
5804e080-cffa-4572-89f0-292a1467ff9a	de9dc531-11bf-4481-882a-dc3291580f60	2025-09-24 14:52:03.556122
dfedeb1d-f7c7-4a09-9749-6c8e60170ada	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2025-09-24 14:56:02.517613
e86da0fb-65a0-42bb-a838-3b68dcf94d39	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2025-09-24 16:36:50.58681
7b14fdfc-bf21-4271-baf2-e88d1e7dc97a	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2025-09-24 16:57:29.653583
3649a840-c62a-4913-97c7-0e5673de5853	6b997217-9ce5-4dda-a9ae-87bf589b92a5	2025-09-24 17:28:12.593984
\.


--
-- TOC entry 3710 (class 0 OID 25808)
-- Dependencies: 227
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.role (role_id, role_name) FROM stdin;
88e07160-2df2-4d18-ab38-9b4668267956	admin
1f65261b-a275-4b10-a71d-a556f3525428	manager
05865b54-4591-4ccb-b1b8-bacf4c8771a2	account:view
\.


--
-- TOC entry 3706 (class 0 OID 25701)
-- Dependencies: 223
-- Data for Name: savings_plan; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.savings_plan (savings_plan_id, plan_name, interest_rate, created_at, updated_at, created_by, updated_by) FROM stdin;
3578bd55-8c57-4757-aa7b-0f37b859edd6	Adult	10.00	2025-09-18 10:25:36.776016	2025-09-18 10:25:36.776016	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
7d8f328d-650d-4e19-b2ef-4c7292f6264a	Joint	7.00	2025-09-18 10:27:13.250715	2025-09-18 10:27:13.250715	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
75cb0dfb-be48-4b4c-ab13-9e01772f0332	Children	12.00	2025-09-18 13:35:04.860764	2025-09-18 13:35:04.860764	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
\.


--
-- TOC entry 3709 (class 0 OID 25789)
-- Dependencies: 226
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.transactions (transaction_id, amount, acc_id, type, description, created_at, created_by, reference_no) FROM stdin;
4d7972d3-31fc-4795-b42a-efec9c31303e	100.00	fb7b432f-634b-4b7c-9ee5-f4ba4a38f531	Deposit	damma	2025-09-18 15:10:00.830901	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	141111295237170
\.


--
-- TOC entry 3702 (class 0 OID 25623)
-- Dependencies: 219
-- Data for Name: user_login; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_login (login_id, user_id, username, password, password_last_update, created_at, updated_at, created_by, updated_by) FROM stdin;
9fdc2462-7532-40da-82d0-2b8a6aad1128	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	system1	$2y$10$2tcVhTKEJ4NRts4lmw5NqOxqhCvQQ94sXMraIyK1YqWZw2Zga9vJW	2025-09-18 06:59:15.461996	2025-09-18 06:59:15.461996	2025-09-18 06:59:15.461996	\N	\N
e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd	de9dc531-11bf-4481-882a-dc3291580f60	user1	$2b$12$3FeUn7kyl4KDB/Yc2w2uUe4wC2OOpRi5bLskalPsihcZ7K2/wRe0K	2025-09-18 07:09:21.535303	2025-09-18 07:09:21.535303	2025-09-18 07:09:21.535303	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1
8e940780-67c7-42e8-a307-4a92664ab72f	6b997217-9ce5-4dda-a9ae-87bf589b92a5	user2	$2b$12$bSFckspDwP6xitca5lzn1.NiWT8qK3Q5nZ5HpD7YsPMP7ky5.7re.	2025-09-18 07:19:23.418837	2025-09-18 07:19:23.418837	2025-09-18 07:19:23.418837	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
e67ce6c6-bb0d-46cf-a222-860e548822a0	780ba9d3-3c4d-40d6-b1a1-c0132f89df09	user3	$2b$12$w8czX6DDYjBiJvdIjOpxVOatGl32Ca4nX40N9A2fWvsPjPTltraB6	2025-09-18 14:04:14.712609	2025-09-18 14:04:14.712609	2025-09-18 14:04:14.712609	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
86295c07-2139-4499-9410-d729b012cfb7	75cf1bda-3240-41c5-8235-5a0f06d51fa7	user4	$2b$12$K4ZpGK2cPR0kivNqhtVRzO6vkOSkFKOkx/zNiAKuREJEqVu.BQ.y2	2025-09-18 14:18:45.238594	2025-09-18 14:18:45.238594	2025-09-18 14:18:45.238594	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60
\.


--
-- TOC entry 3717 (class 0 OID 25933)
-- Dependencies: 234
-- Data for Name: user_refresh_tokens; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_refresh_tokens (token_id, user_id, token_hash, expires_at, is_revoked, device_info, ip_address, created_at, updated_at, revoked_at, revoked_by) FROM stdin;
678d5f69-4663-47e8-bea8-eb083701dcbb	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	2c5ed2099841278465300796097605bd7bf4da5a214a01e2ae08325b458990e1	2025-09-25 01:31:09.924771	f	\N	\N	2025-09-18 07:01:09.83433	2025-09-18 07:01:09.83433	\N	\N
e97ab5ee-d733-40d9-adb2-60769303db42	de9dc531-11bf-4481-882a-dc3291580f60	d63c15766ca38fb841e756e319dfe492e32685c496ebcd232514547aea65f97f	2025-09-25 01:48:25.920403	f	\N	\N	2025-09-18 07:18:25.687636	2025-09-18 07:18:25.687636	\N	\N
d278e2a6-75be-4022-a759-13b93a800452	de9dc531-11bf-4481-882a-dc3291580f60	dbea4ade6837a2361f4e00caea0b70457f8d213ca1576a2356ffc5ae85090017	2025-09-25 08:32:15.671082	f	\N	\N	2025-09-18 14:02:15.403076	2025-09-18 14:02:15.403076	\N	\N
3fb7573a-2b5d-4da7-ad2f-e55831856fb6	de9dc531-11bf-4481-882a-dc3291580f60	7c6563ffd9b3a8edb58c1b1a5a741da3c7075e39fce1a28deabd7947aa522e9d	2025-09-28 18:42:51.787149	f	\N	\N	2025-09-22 00:12:51.514948	2025-09-22 00:12:51.514948	\N	\N
136e984c-4dbf-4d50-b831-1b0316e979ed	de9dc531-11bf-4481-882a-dc3291580f60	34853a230f98bff61d707354caa89a12fe71457b0be2ad500786d05083b76792	2025-09-28 18:43:31.502704	f	\N	\N	2025-09-22 00:13:31.270299	2025-09-22 00:13:31.270299	\N	\N
a2791147-04b2-4075-aba5-5904ee58207a	de9dc531-11bf-4481-882a-dc3291580f60	91d5e79c9b6fac6b12fbfc2098358744b47ba10c7935f5d33d856ab69f946e83	2025-09-28 18:49:04.876643	f	\N	\N	2025-09-22 00:19:04.642045	2025-09-22 00:19:04.642045	\N	\N
c353bc1d-57d7-4040-a54a-e160fa2bfa90	de9dc531-11bf-4481-882a-dc3291580f60	121bfaae54c9fe99f0691f903b4fabe8764935a5f6c42f1bdfac225f8e6cd593	2025-09-28 18:51:39.066589	f	\N	\N	2025-09-22 00:21:38.833204	2025-09-22 00:21:38.833204	\N	\N
6a0e5bbf-d470-43f5-9175-0f7b6164aaaf	de9dc531-11bf-4481-882a-dc3291580f60	f47121511925c07e5582df3cfd6650592d8937602ce052cd26b5f8672c1fabcd	2025-09-29 02:59:33.63813	f	\N	\N	2025-09-22 08:29:33.021735	2025-09-22 08:29:33.021735	\N	\N
f9fa1fc8-515f-4882-8bff-52d69748c972	de9dc531-11bf-4481-882a-dc3291580f60	89baf09f5df5970e519394d2b9a6ecdb31c04cc206d1a30e768f5c0c425b5fe9	2025-09-29 03:06:07.235559	f	\N	\N	2025-09-22 08:36:06.737813	2025-09-22 08:36:06.737813	\N	\N
93f69804-da1c-4fc1-abec-cea2d75695ad	de9dc531-11bf-4481-882a-dc3291580f60	3a1559798a58ecc48c911dd8cbd8e0366c0c30c6f46880818ba8535e476bc665	2025-09-29 03:08:45.674032	f	\N	\N	2025-09-22 08:38:45.254825	2025-09-22 08:38:45.254825	\N	\N
27a65582-f6c4-4a1e-b820-e6c91bc11893	de9dc531-11bf-4481-882a-dc3291580f60	5c654b49dc31523bd6370d4bdb9e1bf0b97495eff5dcf352ef395f45fb65cd68	2025-09-29 03:08:45.827703	f	\N	\N	2025-09-22 08:38:45.414417	2025-09-22 08:38:45.414417	\N	\N
be9e85be-a678-48b7-8f07-35b8a9032d79	de9dc531-11bf-4481-882a-dc3291580f60	0dce2441dd43d3ea78e752b45cac5bff384eef6a65e4cc0d1e1f47259571d168	2025-09-29 03:42:44.155956	f	\N	\N	2025-09-22 09:12:43.885577	2025-09-22 09:12:43.885577	\N	\N
f7e2b444-aeb6-4aaf-b993-06bddc2dd2b2	de9dc531-11bf-4481-882a-dc3291580f60	71d6c665af6d4f1d3f233a67ae851eacaa49830b85bd8150b17a9609e8b2be03	2025-09-29 03:45:19.048552	f	\N	\N	2025-09-22 09:15:18.79815	2025-09-22 09:15:18.79815	\N	\N
0d6fc872-aa8f-4426-97a8-d5d3777dc2de	de9dc531-11bf-4481-882a-dc3291580f60	e4e0b61e28762577108affb88a408d224d8482c16f44241cca85e7f2840099df	2025-09-29 03:56:09.182414	f	\N	\N	2025-09-22 09:26:08.907774	2025-09-22 09:26:08.907774	\N	\N
f83fdac6-7ba2-473e-a23b-bfecbea05e26	de9dc531-11bf-4481-882a-dc3291580f60	dfadf9782ddfb37b5adfcc575911c1d1936f4c7a0f38463e815fe785eb1cd2ca	2025-09-29 03:58:10.789453	f	\N	\N	2025-09-22 09:28:10.537577	2025-09-22 09:28:10.537577	\N	\N
038360be-1bc2-4ba3-a773-c482cac9dc5e	de9dc531-11bf-4481-882a-dc3291580f60	80b3c0251d9bca24d1538e7ec38f0e70dba1514df1c8a44b7d68418b78502fdc	2025-09-29 03:58:51.847145	f	\N	\N	2025-09-22 09:28:51.596043	2025-09-22 09:28:51.596043	\N	\N
452572c5-87d2-4357-9d00-c0f595f1503c	de9dc531-11bf-4481-882a-dc3291580f60	498076d68c79a1bea597d02b1e0e98be3555867f4f075fe8e2a700a3c968d9b5	2025-09-29 04:00:11.10285	f	\N	\N	2025-09-22 09:30:10.841071	2025-09-22 09:30:10.841071	\N	\N
2fd8d0fb-402c-4073-8025-3bdc8dc59f62	de9dc531-11bf-4481-882a-dc3291580f60	1f432c987b70bcf47c1501c6fed46fb3546cc925cf3978f67fa6f68ee2a0998a	2025-09-29 04:00:18.180009	f	\N	\N	2025-09-22 09:30:17.911547	2025-09-22 09:30:17.911547	\N	\N
4f90396f-f863-4a40-af18-4160f822483f	de9dc531-11bf-4481-882a-dc3291580f60	92da0842ac9c89d72ecf8e2d5411bdf30874ed73490c03ab5766cf91951aa8d0	2025-09-29 04:03:49.141391	f	\N	\N	2025-09-22 09:33:48.885342	2025-09-22 09:33:48.885342	\N	\N
f5074ff1-960f-48b0-b367-71148c111140	de9dc531-11bf-4481-882a-dc3291580f60	2bd361d4c9f525bb804ece0bce16bf2d86f7f0a94cdc09110f848231330c97d4	2025-09-29 04:04:04.457679	f	\N	\N	2025-09-22 09:34:04.219523	2025-09-22 09:34:04.219523	\N	\N
7eafd257-742b-42c6-947b-1fa989fc135a	de9dc531-11bf-4481-882a-dc3291580f60	3734e29ccc09feab760c25cd623b18dcacba8fa82e23dfbb85d4e6678e6a3599	2025-09-29 04:04:30.287874	f	\N	\N	2025-09-22 09:34:30.056893	2025-09-22 09:34:30.056893	\N	\N
ecadd80a-ba04-4c99-a694-581a9d622c8b	de9dc531-11bf-4481-882a-dc3291580f60	209d4c6deb979daad93a2297263fb87698c98f2842e003f79bb8e55f31de30e1	2025-09-29 04:09:29.916281	f	\N	\N	2025-09-22 09:39:29.663651	2025-09-22 09:39:29.663651	\N	\N
bc638332-d4f7-4a15-949e-6c405b348756	de9dc531-11bf-4481-882a-dc3291580f60	420cf564f8bc00981e2725c26569793b322546123237ff422fe4d67aea7221f0	2025-09-29 04:10:00.31555	f	\N	\N	2025-09-22 09:40:00.06446	2025-09-22 09:40:00.06446	\N	\N
2d2a7dd2-2af3-42ce-b584-c83bfa10b4eb	de9dc531-11bf-4481-882a-dc3291580f60	8fd76cc303f396056159bc3b82a4d0f3449339462b3c146e4cfa1a13ed3e0b00	2025-09-29 04:11:12.980692	f	\N	\N	2025-09-22 09:41:12.726653	2025-09-22 09:41:12.726653	\N	\N
e7291f88-f47d-4305-9c68-3bf2c262ea4b	de9dc531-11bf-4481-882a-dc3291580f60	4be6f6eceab5d288a86e6da8714c619f06942ad292c9768840aaa0c2f2e780a1	2025-09-29 04:11:26.516601	f	\N	\N	2025-09-22 09:41:26.253239	2025-09-22 09:41:26.253239	\N	\N
315e5c13-87c3-4757-b3ca-44a0191f212d	de9dc531-11bf-4481-882a-dc3291580f60	06a8a3fc2f35d01faf74a95364af7a08fbdc32505e97a0784be75ec35253923f	2025-09-29 04:13:22.660165	f	\N	\N	2025-09-22 09:43:22.383229	2025-09-22 09:43:22.383229	\N	\N
3a776b49-cd97-439f-984f-9c8124fb5b51	de9dc531-11bf-4481-882a-dc3291580f60	e2df27d44cb578b95153b74c9d3509ab75651316b28c259f64bfab6d4be7e52a	2025-09-29 04:44:56.640162	f	\N	\N	2025-09-22 10:14:56.408403	2025-09-22 10:14:56.408403	\N	\N
1dc04405-e044-4930-be93-6c1504cc0827	de9dc531-11bf-4481-882a-dc3291580f60	2781687fa9a545ca8f7f1fd838eaf74b647110d9426bbe9da6015282f0b93f8e	2025-09-29 04:45:16.804358	f	\N	\N	2025-09-22 10:15:16.572024	2025-09-22 10:15:16.572024	\N	\N
00f58b70-6075-4717-877b-3cbeb8495576	de9dc531-11bf-4481-882a-dc3291580f60	a01a4169dbcffdec13fe386be5d7cb6fd55a21a0715b281ff7d48abbcadf5632	2025-09-29 04:48:53.234741	f	\N	\N	2025-09-22 10:18:52.975545	2025-09-22 10:18:52.975545	\N	\N
fcd57137-8f89-442f-a621-2cdce8b201a8	de9dc531-11bf-4481-882a-dc3291580f60	5ecbd1d4705ab49222d29b37a543bda087b40450e2fd8405c4e985e44e934010	2025-09-29 04:50:50.928659	f	\N	\N	2025-09-22 10:20:50.697348	2025-09-22 10:20:50.697348	\N	\N
850b82ed-f3e0-4133-81a1-e50c42fbcbb8	de9dc531-11bf-4481-882a-dc3291580f60	baa200ee2738007a6f71bc91969e8f5aaf71b5bc5769f6caed82b60e8c75ec87	2025-09-29 04:51:08.492127	f	\N	\N	2025-09-22 10:21:08.25983	2025-09-22 10:21:08.25983	\N	\N
644e361f-5830-483d-8840-ed404a211286	de9dc531-11bf-4481-882a-dc3291580f60	ea8ad949983640055e03ed6c0d1b447067e23d3a7ff8dfb5a317b582008b33c8	2025-09-29 04:54:36.97248	f	\N	\N	2025-09-22 10:24:36.720264	2025-09-22 10:24:36.720264	\N	\N
13f033ee-a45e-4b0f-bfbf-8db1aa4f5965	de9dc531-11bf-4481-882a-dc3291580f60	7c34c30bbb9a0c1d2689405240c10892af2d0ba7705f3943e96eff887a3e72a3	2025-09-29 04:54:37.117265	f	\N	\N	2025-09-22 10:24:36.885382	2025-09-22 10:24:36.885382	\N	\N
4d2ed287-427b-4a7d-adda-934e55377cd2	de9dc531-11bf-4481-882a-dc3291580f60	8e2a9574dfc936eb8fe22b7d621efb5dd8e175b3eca846ef77053b2618a8325c	2025-09-29 06:28:36.803607	f	\N	\N	2025-09-22 11:58:36.551429	2025-09-22 11:58:36.551429	\N	\N
4c823fdc-11da-4e0f-afce-69a5d731dac1	de9dc531-11bf-4481-882a-dc3291580f60	45438d30bd71039871f2cd26549c2df35e2484cce32900d78f8a18bb070a24f9	2025-09-29 07:02:14.453181	f	\N	\N	2025-09-22 12:32:14.212019	2025-09-22 12:32:14.212019	\N	\N
a2a3bd18-3f54-47d8-be9e-c697cf4fbce4	de9dc531-11bf-4481-882a-dc3291580f60	f055e569a05727f4df20aa54aac95d7084e016745186eb377827eef10be815f1	2025-09-29 07:12:22.104072	f	\N	\N	2025-09-22 12:42:21.849122	2025-09-22 12:42:21.849122	\N	\N
693603bd-ad6a-4063-aa2b-c7118337e35c	de9dc531-11bf-4481-882a-dc3291580f60	6dcc75083cfbc9df38f6afbbe0414a199f425bc544c5080901d90a0e58a37a15	2025-09-29 07:15:53.246691	f	\N	\N	2025-09-22 12:45:52.987045	2025-09-22 12:45:52.987045	\N	\N
fc6f15eb-ad26-44f7-b117-baacf3f465c8	de9dc531-11bf-4481-882a-dc3291580f60	d556f3ef026c1dd03b5093003f2f78ffddb0eec8879e8f4fbbb64779457016f2	2025-09-29 07:21:19.635361	f	\N	\N	2025-09-22 12:51:19.380084	2025-09-22 12:51:19.380084	\N	\N
b139f19b-344d-4b57-beb4-56a84f7e2696	de9dc531-11bf-4481-882a-dc3291580f60	19bf8e989d5db590e2d914a32db3a5ae7dcc6bb89fe2434b20858f9b0c474d5b	2025-09-29 07:22:08.662156	f	\N	\N	2025-09-22 12:52:08.409941	2025-09-22 12:52:08.409941	\N	\N
530d5cb2-24f7-4e3f-ba8e-e2741514053e	de9dc531-11bf-4481-882a-dc3291580f60	2a0b8ed46142e2f0ede7192a0cd43f110ce05701e7d51e6fc041043a5f6bf53a	2025-09-29 07:24:08.892925	f	\N	\N	2025-09-22 12:54:08.62085	2025-09-22 12:54:08.62085	\N	\N
e0a578e2-6a51-4825-81ad-f8e1366ad254	de9dc531-11bf-4481-882a-dc3291580f60	47467934e5ffbafd847b46d47983b47cfa6022e516d98ead7065a0cbdbcaa735	2025-09-29 07:25:40.118696	f	\N	\N	2025-09-22 12:55:39.884308	2025-09-22 12:55:39.884308	\N	\N
2a36bf3e-d485-4e47-b07c-1c6b63a8a14a	de9dc531-11bf-4481-882a-dc3291580f60	caef878c40cd624fc7d870413b2c5a1b013b5da3b6a9eb2c3ffe0647d1c4727c	2025-09-29 07:51:08.869286	f	\N	\N	2025-09-22 13:21:08.392618	2025-09-22 13:21:08.392618	\N	\N
a900dbb1-e3ad-47a2-a94f-d0f8d81b9bc0	de9dc531-11bf-4481-882a-dc3291580f60	f00a006bc92462a0600894fe7b2962902b49cb3a014195b3dcd0c60f56baa2e4	2025-09-29 09:25:55.064702	f	\N	\N	2025-09-22 14:55:54.79285	2025-09-22 14:55:54.79285	\N	\N
e96c8083-2b22-47a9-8183-df9129e851c6	de9dc531-11bf-4481-882a-dc3291580f60	773fdb451c507f16ae1fb9bc00dc3adcc5cbb6cd298bf8aa4088736c5e076228	2025-09-29 09:32:07.283396	f	\N	\N	2025-09-22 15:02:07.053462	2025-09-22 15:02:07.053462	\N	\N
1b2e2b3c-9ba8-47b6-89ba-e0335e206faf	de9dc531-11bf-4481-882a-dc3291580f60	148de9081d97afe50e648a6d286a5e9b451fb5be5592a277214591a511ea690a	2025-09-29 09:32:34.491253	f	\N	\N	2025-09-22 15:02:34.238956	2025-09-22 15:02:34.238956	\N	\N
ab7d688e-cb28-40d5-8bbc-f0ec85547173	de9dc531-11bf-4481-882a-dc3291580f60	588c2e70b71df89c4a4946fcffd3b0184560544a4c40899e55fbf80834cfb8fc	2025-09-29 09:34:55.16318	f	\N	\N	2025-09-22 15:04:54.918854	2025-09-22 15:04:54.918854	\N	\N
65ef63d9-c699-4601-b0ed-4dc5c8f65daf	de9dc531-11bf-4481-882a-dc3291580f60	d70cc7456e81e084f3dc6d8ddc4bd2e0db2ebd667a5ec83320d62e6a6fb6a95e	2025-09-30 10:35:23.587345	f	\N	\N	2025-09-23 16:05:23.126818	2025-09-23 16:05:23.126818	\N	\N
abf03ac8-e08a-4d47-94c6-67624d30ec38	de9dc531-11bf-4481-882a-dc3291580f60	4fe70cd217464782e64528e77905dccb32246e30d441b17f6b0ab72f9797c0be	2025-09-30 10:38:08.732006	f	\N	\N	2025-09-23 16:08:08.48046	2025-09-23 16:08:08.48046	\N	\N
8a949d63-3b01-41f6-bac6-0f8cf4a570e9	de9dc531-11bf-4481-882a-dc3291580f60	19ac11c2be5c60e6afc5746d5db0b17910316c050dcee3af1795704691a7c816	2025-09-30 10:45:51.915646	f	\N	\N	2025-09-23 16:15:51.642926	2025-09-23 16:15:51.642926	\N	\N
c0fda872-78b9-42b7-b0ba-d665a6021cfd	de9dc531-11bf-4481-882a-dc3291580f60	a3873d3a483128eb057e9160687b47fc1857edcb638ac1c5b3575f4960b51b4e	2025-09-30 10:55:24.526677	f	\N	\N	2025-09-23 16:25:24.27206	2025-09-23 16:25:24.27206	\N	\N
7960636f-f314-4d0b-86ae-1d7218ad9cc1	de9dc531-11bf-4481-882a-dc3291580f60	e11463e20934042d76ce16f2bce19a3ba2436b2d99ddec7d006ded8f992cb40d	2025-09-30 10:59:03.252781	f	\N	\N	2025-09-23 16:29:03.000119	2025-09-23 16:29:03.000119	\N	\N
0b3bb9a9-120b-4cf5-a73d-31742260c53d	de9dc531-11bf-4481-882a-dc3291580f60	c5711e1700590c619f5704eeeacb4071992575b66d4c7198d93ff2e28bea0e33	2025-09-30 11:00:35.181193	f	\N	\N	2025-09-23 16:30:34.941337	2025-09-23 16:30:34.941337	\N	\N
ab51d161-7dcb-4e8b-94db-39ca43bded9f	de9dc531-11bf-4481-882a-dc3291580f60	7d4eb8e4f96b53437dc694a26f22e3d1d120d756a8dda00539de077a35ce29a7	2025-09-30 11:01:04.77882	f	\N	\N	2025-09-23 16:31:04.536494	2025-09-23 16:31:04.536494	\N	\N
b311f611-7d61-4541-b662-e0b459297f63	de9dc531-11bf-4481-882a-dc3291580f60	b01d726a600a87da527872df5339326fc5b4cf1689ce3a22d4592a4627ace999	2025-09-30 11:04:51.940308	f	\N	\N	2025-09-23 16:34:51.6875	2025-09-23 16:34:51.6875	\N	\N
17cb2bff-b4b5-4acf-8cc9-98797a05b332	de9dc531-11bf-4481-882a-dc3291580f60	e3a88cc4b0949bd4e4e4202cfaaf292516a7adcd793669ca29807d1fcf64b917	2025-09-30 11:09:28.157569	f	\N	\N	2025-09-23 16:39:27.905343	2025-09-23 16:39:27.905343	\N	\N
42a7c414-ed8e-46e6-b714-6e54a5d7345d	de9dc531-11bf-4481-882a-dc3291580f60	baf4603ee2a6196bfe38e3649497345b99a25fc6a01e283eeb8c65a812ae69f0	2025-09-30 11:18:10.592943	f	\N	\N	2025-09-23 16:48:10.340503	2025-09-23 16:48:10.340503	\N	\N
9e795957-1879-4eb4-abe3-4406216cc532	de9dc531-11bf-4481-882a-dc3291580f60	12ee9cec6f628fc68824d379211a8444eaf5c62ca06d40af3441b870b0ab6cb8	2025-09-30 11:23:14.773314	f	\N	\N	2025-09-23 16:53:14.520733	2025-09-23 16:53:14.520733	\N	\N
de8111b5-ce5c-4836-878f-f0605dab6e5b	de9dc531-11bf-4481-882a-dc3291580f60	863a07b4aeec3a88c8d580f53b1935e482c44f15ea68709e9f763b8ec52590fc	2025-09-30 12:52:57.782635	f	\N	\N	2025-09-23 18:22:57.486665	2025-09-23 18:22:57.486665	\N	\N
0c4f5f59-7b8a-4bf2-9926-01af68a2c51f	de9dc531-11bf-4481-882a-dc3291580f60	549ea34c9ef4ed499780c0b01567d0345b3e148b55b70bc8417f2f1906575191	2025-09-30 12:57:18.47642	f	\N	\N	2025-09-23 18:27:18.244325	2025-09-23 18:27:18.244325	\N	\N
89798fca-92cc-4793-91b0-0e702705e9bc	de9dc531-11bf-4481-882a-dc3291580f60	649d8ab338a6eb55245448e2c4d6ceca4b9c7eb5a45085f68de9dc7650d4433d	2025-09-30 13:28:43.307566	f	\N	\N	2025-09-23 18:58:43.045183	2025-09-23 18:58:43.045183	\N	\N
fe0ac8d6-887b-457c-a447-67c399f3e267	de9dc531-11bf-4481-882a-dc3291580f60	5bf917328a85e584ac56db5b3dd0fc06762b8aee11e184afed284966258d48da	2025-09-30 13:33:40.988626	f	\N	\N	2025-09-23 19:03:40.715682	2025-09-23 19:03:40.715682	\N	\N
5b7ec7e1-9410-4c6e-84e3-fa253d7ec816	de9dc531-11bf-4481-882a-dc3291580f60	8775d732301019a3a724c87ad1c62bc1b16c64264fab0d0ff3651a2628a38d54	2025-09-30 13:36:33.789978	f	\N	\N	2025-09-23 19:06:33.509643	2025-09-23 19:06:33.509643	\N	\N
aa168f18-ff15-41a9-9b29-b4e392ae3380	de9dc531-11bf-4481-882a-dc3291580f60	bd4a4aa342a0834b958adbeefd44a9f2aa359d428a8c8498f3deb12fd933e062	2025-09-30 13:39:20.207226	f	\N	\N	2025-09-23 19:09:19.97633	2025-09-23 19:09:19.97633	\N	\N
5b3015bb-3be9-4101-beb2-cd5863c14613	de9dc531-11bf-4481-882a-dc3291580f60	5d97dd7c0bb2b6d7d3f6e8eff3610bd98f5ede65e3b1c5cdb84c04e32b4b76fb	2025-09-30 13:48:56.240045	f	\N	\N	2025-09-23 19:18:55.954682	2025-09-23 19:18:55.954682	\N	\N
6f5d6c95-cbfb-41c1-90b0-d0887aa84214	de9dc531-11bf-4481-882a-dc3291580f60	d2cf6ceb0e36ffb65d23597098698449309f9a79dd3b377f0ca7f0c3a60151f5	2025-10-01 09:22:03.554038	f	\N	\N	2025-09-24 14:52:03.297909	2025-09-24 14:52:03.297909	\N	\N
861a073a-5834-4aed-8fbe-d2ebeb46cd7f	6b997217-9ce5-4dda-a9ae-87bf589b92a5	4fb8821f9a1919e7f5430c0ee4b75ed98b8f434038b3bd339cb140437c71348b	2025-10-01 09:26:02.515441	f	\N	\N	2025-09-24 14:56:02.283902	2025-09-24 14:56:02.283902	\N	\N
0519e47e-4e53-47f5-95df-408a868374a9	6b997217-9ce5-4dda-a9ae-87bf589b92a5	d16a2004c95e89198cac3b5a189811739c5502fd901d46dc585ee88d3bb4bb94	2025-10-01 11:06:50.584446	f	\N	\N	2025-09-24 16:36:50.333405	2025-09-24 16:36:50.333405	\N	\N
6489b42d-3e14-44fb-8853-b361ba3517c9	6b997217-9ce5-4dda-a9ae-87bf589b92a5	1a160d7875edbfa2ca0b9feb22e823ea7918d4cf591690f820ab644ed480b08c	2025-10-01 11:27:29.651773	f	\N	\N	2025-09-24 16:57:29.401124	2025-09-24 16:57:29.401124	\N	\N
37b839a8-7d84-4819-9366-cc348f8e3e2f	6b997217-9ce5-4dda-a9ae-87bf589b92a5	e02d8d6a7efafc43b2b6c1a23ebaf7bb0deed5bc863f39314675a6f2a75efe51	2025-10-01 11:58:12.592011	f	\N	\N	2025-09-24 17:28:12.337543	2025-09-24 17:28:12.337543	\N	\N
\.


--
-- TOC entry 3701 (class 0 OID 25603)
-- Dependencies: 218
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (user_id, nic, first_name, last_name, address, phone_number, dob, created_at, updated_at, created_by, updated_by, email) FROM stdin;
839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	\N	System 	main	\N	\N	\N	2025-09-18 06:57:17.48252	2025-09-18 06:57:17.48252	\N	\N	\N
de9dc531-11bf-4481-882a-dc3291580f60	200325314526	user1	user1	user 1  address	0765898755	2003-01-01	2025-09-18 07:09:21.535303	2025-09-18 07:09:21.535303	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	839c9a79-9f0a-4ba7-9d4c-91358f9b93b1	\N
6b997217-9ce5-4dda-a9ae-87bf589b92a5	200325314527	user2	user2	user 2  address	0765898745	2003-01-01	2025-09-18 07:19:23.418837	2025-09-18 07:21:06.077114	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60	\N
780ba9d3-3c4d-40d6-b1a1-c0132f89df09	200135645879	user3	user3	jafna	045789866	2004-10-10	2025-09-18 14:04:14.712609	2025-09-18 14:04:14.712609	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60	\N
75cf1bda-3240-41c5-8235-5a0f06d51fa7	200135645870	user4	user4	jafna	045789866	2004-10-10	2025-09-18 14:18:45.238594	2025-09-18 14:18:45.238594	de9dc531-11bf-4481-882a-dc3291580f60	de9dc531-11bf-4481-882a-dc3291580f60	\N
\.


--
-- TOC entry 3714 (class 0 OID 25881)
-- Dependencies: 231
-- Data for Name: users_branch; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users_branch (user_id, branch_id) FROM stdin;
6b997217-9ce5-4dda-a9ae-87bf589b92a5	3dd6870c-e6f2-414d-9973-309ba00ce115
780ba9d3-3c4d-40d6-b1a1-c0132f89df09	57438d7f-184f-42fe-b0d6-91a2ef609beb
\.


--
-- TOC entry 3711 (class 0 OID 25816)
-- Dependencies: 228
-- Data for Name: users_role; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users_role (user_id, role_id) FROM stdin;
de9dc531-11bf-4481-882a-dc3291580f60	88e07160-2df2-4d18-ab38-9b4668267956
de9dc531-11bf-4481-882a-dc3291580f60	05865b54-4591-4ccb-b1b8-bacf4c8771a2
6b997217-9ce5-4dda-a9ae-87bf589b92a5	1f65261b-a275-4b10-a71d-a556f3525428
\.


--
-- TOC entry 3459 (class 2606 OID 26861)
-- Name: account account_account_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_account_no_key UNIQUE (account_no);


--
-- TOC entry 3461 (class 2606 OID 26872)
-- Name: account account_no_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_no_unique UNIQUE (account_no);


--
-- TOC entry 3463 (class 2606 OID 25727)
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (acc_id);


--
-- TOC entry 3496 (class 2606 OID 25900)
-- Name: accounts_owner accounts_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_pkey PRIMARY KEY (acc_id, customer_id);


--
-- TOC entry 3498 (class 2606 OID 25927)
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id);


--
-- TOC entry 3453 (class 2606 OID 25672)
-- Name: branch branch_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_pkey PRIMARY KEY (branch_id);


--
-- TOC entry 3488 (class 2606 OID 25863)
-- Name: customer_login customer_login_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_key UNIQUE (customer_id);


--
-- TOC entry 3490 (class 2606 OID 25861)
-- Name: customer_login customer_login_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3492 (class 2606 OID 25865)
-- Name: customer_login customer_login_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_username_key UNIQUE (username);


--
-- TOC entry 3482 (class 2606 OID 25840)
-- Name: customer customer_nic_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_nic_key UNIQUE (nic);


--
-- TOC entry 3484 (class 2606 OID 25838)
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- TOC entry 3455 (class 2606 OID 25690)
-- Name: fd_plan fd_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_pkey PRIMARY KEY (fd_plan_id);


--
-- TOC entry 3467 (class 2606 OID 25758)
-- Name: fixed_deposit fixed_deposit_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_pkey PRIMARY KEY (fd_id);


--
-- TOC entry 3451 (class 2606 OID 25659)
-- Name: login login_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_pkey PRIMARY KEY (log_id);


--
-- TOC entry 3476 (class 2606 OID 25813)
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (role_id);


--
-- TOC entry 3478 (class 2606 OID 25815)
-- Name: role role_role_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_role_name_key UNIQUE (role_name);


--
-- TOC entry 3457 (class 2606 OID 25708)
-- Name: savings_plan savings_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_pkey PRIMARY KEY (savings_plan_id);


--
-- TOC entry 3472 (class 2606 OID 25797)
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (transaction_id);


--
-- TOC entry 3474 (class 2606 OID 26839)
-- Name: transactions transactions_reference_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_reference_no_key UNIQUE (reference_no);


--
-- TOC entry 3443 (class 2606 OID 25633)
-- Name: user_login user_login_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3445 (class 2606 OID 25635)
-- Name: user_login user_login_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_key UNIQUE (user_id);


--
-- TOC entry 3447 (class 2606 OID 25637)
-- Name: user_login user_login_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_username_key UNIQUE (username);


--
-- TOC entry 3507 (class 2606 OID 25943)
-- Name: user_refresh_tokens user_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_pkey PRIMARY KEY (token_id);


--
-- TOC entry 3494 (class 2606 OID 25885)
-- Name: users_branch users_branch_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_pkey PRIMARY KEY (user_id, branch_id);


--
-- TOC entry 3439 (class 2606 OID 25612)
-- Name: users users_nic_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_nic_key UNIQUE (nic);


--
-- TOC entry 3441 (class 2606 OID 25610)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- TOC entry 3480 (class 2606 OID 25820)
-- Name: users_role users_role_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_pkey PRIMARY KEY (user_id, role_id);


--
-- TOC entry 3464 (class 1259 OID 26862)
-- Name: idx_account_account_no; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_account_account_no ON public.account USING btree (account_no);


--
-- TOC entry 3465 (class 1259 OID 25971)
-- Name: idx_account_branch_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_account_branch_id ON public.account USING btree (branch_id);


--
-- TOC entry 3499 (class 1259 OID 25975)
-- Name: idx_audit_log_table_record; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_table_record ON public.audit_log USING btree (table_name, record_id);


--
-- TOC entry 3500 (class 1259 OID 25976)
-- Name: idx_audit_log_timestamp; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_timestamp ON public.audit_log USING btree ("timestamp");


--
-- TOC entry 3501 (class 1259 OID 25977)
-- Name: idx_audit_log_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_user_id ON public.audit_log USING btree (user_id);


--
-- TOC entry 3485 (class 1259 OID 25969)
-- Name: idx_customer_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customer_created_at ON public.customer USING btree (created_at);


--
-- TOC entry 3486 (class 1259 OID 25968)
-- Name: idx_customer_nic; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customer_nic ON public.customer USING btree (nic);


--
-- TOC entry 3448 (class 1259 OID 25979)
-- Name: idx_login_time; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_login_time ON public.login USING btree (login_time);


--
-- TOC entry 3449 (class 1259 OID 25978)
-- Name: idx_login_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_login_user_id ON public.login USING btree (user_id);


--
-- TOC entry 3468 (class 1259 OID 25972)
-- Name: idx_transactions_acc_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_transactions_acc_id ON public.transactions USING btree (acc_id);


--
-- TOC entry 3469 (class 1259 OID 25973)
-- Name: idx_transactions_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at);


--
-- TOC entry 3470 (class 1259 OID 25974)
-- Name: idx_transactions_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_transactions_type ON public.transactions USING btree (type);


--
-- TOC entry 3502 (class 1259 OID 25983)
-- Name: idx_user_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_refresh_tokens_expires_at ON public.user_refresh_tokens USING btree (expires_at);


--
-- TOC entry 3503 (class 1259 OID 25982)
-- Name: idx_user_refresh_tokens_hash; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_refresh_tokens_hash ON public.user_refresh_tokens USING btree (token_hash);


--
-- TOC entry 3504 (class 1259 OID 25984)
-- Name: idx_user_refresh_tokens_revoked; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_refresh_tokens_revoked ON public.user_refresh_tokens USING btree (is_revoked);


--
-- TOC entry 3505 (class 1259 OID 25981)
-- Name: idx_user_refresh_tokens_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_refresh_tokens_user_id ON public.user_refresh_tokens USING btree (user_id);


--
-- TOC entry 3436 (class 1259 OID 25967)
-- Name: idx_users_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_created_at ON public.users USING btree (created_at);


--
-- TOC entry 3437 (class 1259 OID 25966)
-- Name: idx_users_nic; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_nic ON public.users USING btree (nic);


--
-- TOC entry 3550 (class 2620 OID 25961)
-- Name: account update_account_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_account_updated_at BEFORE UPDATE ON public.account FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3547 (class 2620 OID 25958)
-- Name: branch update_branch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_branch_updated_at BEFORE UPDATE ON public.branch FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3554 (class 2620 OID 25965)
-- Name: customer_login update_customer_login_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_customer_login_updated_at BEFORE UPDATE ON public.customer_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3553 (class 2620 OID 25964)
-- Name: customer update_customer_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_customer_updated_at BEFORE UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3548 (class 2620 OID 25959)
-- Name: fd_plan update_fd_plan_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_fd_plan_updated_at BEFORE UPDATE ON public.fd_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3551 (class 2620 OID 25962)
-- Name: fixed_deposit update_fixed_deposit_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_fixed_deposit_updated_at BEFORE UPDATE ON public.fixed_deposit FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3552 (class 2620 OID 25963)
-- Name: role update_role_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_role_updated_at BEFORE UPDATE ON public.role FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3549 (class 2620 OID 25960)
-- Name: savings_plan update_savings_plan_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_savings_plan_updated_at BEFORE UPDATE ON public.savings_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3545 (class 2620 OID 25957)
-- Name: user_login update_user_login_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_user_login_updated_at BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3555 (class 2620 OID 25980)
-- Name: user_refresh_tokens update_user_refresh_tokens_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_user_refresh_tokens_updated_at BEFORE UPDATE ON public.user_refresh_tokens FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3544 (class 2620 OID 25956)
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3546 (class 2620 OID 26834)
-- Name: user_login user_login_update_audit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER user_login_update_audit BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.audit_user_login_update();


--
-- TOC entry 3520 (class 2606 OID 25730)
-- Name: account account_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3521 (class 2606 OID 25740)
-- Name: account account_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3522 (class 2606 OID 25735)
-- Name: account account_savings_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_savings_plan_id_fkey FOREIGN KEY (savings_plan_id) REFERENCES public.savings_plan(savings_plan_id);


--
-- TOC entry 3523 (class 2606 OID 25745)
-- Name: account account_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3539 (class 2606 OID 25901)
-- Name: accounts_owner accounts_owner_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3540 (class 2606 OID 25906)
-- Name: accounts_owner accounts_owner_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- TOC entry 3541 (class 2606 OID 25928)
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3514 (class 2606 OID 25673)
-- Name: branch branch_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3515 (class 2606 OID 25678)
-- Name: branch branch_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3532 (class 2606 OID 25841)
-- Name: customer customer_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3534 (class 2606 OID 25866)
-- Name: customer_login customer_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3535 (class 2606 OID 25876)
-- Name: customer_login customer_login_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON DELETE CASCADE;


--
-- TOC entry 3536 (class 2606 OID 25871)
-- Name: customer_login customer_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3533 (class 2606 OID 25846)
-- Name: customer customer_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3516 (class 2606 OID 25691)
-- Name: fd_plan fd_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3517 (class 2606 OID 25696)
-- Name: fd_plan fd_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3524 (class 2606 OID 25759)
-- Name: fixed_deposit fixed_deposit_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3525 (class 2606 OID 25769)
-- Name: fixed_deposit fixed_deposit_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3526 (class 2606 OID 25764)
-- Name: fixed_deposit fixed_deposit_fd_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_fd_plan_id_fkey FOREIGN KEY (fd_plan_id) REFERENCES public.fd_plan(fd_plan_id);


--
-- TOC entry 3527 (class 2606 OID 25774)
-- Name: fixed_deposit fixed_deposit_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3513 (class 2606 OID 25660)
-- Name: login login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3518 (class 2606 OID 25709)
-- Name: savings_plan savings_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3519 (class 2606 OID 25714)
-- Name: savings_plan savings_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3528 (class 2606 OID 25798)
-- Name: transactions transactions_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3529 (class 2606 OID 25803)
-- Name: transactions transactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3510 (class 2606 OID 25638)
-- Name: user_login user_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3511 (class 2606 OID 25643)
-- Name: user_login user_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3512 (class 2606 OID 25648)
-- Name: user_login user_login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- TOC entry 3542 (class 2606 OID 25944)
-- Name: user_refresh_tokens user_refresh_tokens_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES public.users(user_id);


--
-- TOC entry 3543 (class 2606 OID 25949)
-- Name: user_refresh_tokens user_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3537 (class 2606 OID 25891)
-- Name: users_branch users_branch_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3538 (class 2606 OID 25886)
-- Name: users_branch users_branch_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3508 (class 2606 OID 25613)
-- Name: users users_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3530 (class 2606 OID 25826)
-- Name: users_role users_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(role_id);


--
-- TOC entry 3531 (class 2606 OID 25821)
-- Name: users_role users_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3509 (class 2606 OID 25618)
-- Name: users users_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3725 (class 0 OID 0)
-- Dependencies: 6
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: postgres
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;


-- Completed on 2025-09-24 19:47:46 +0530

--
-- PostgreSQL database dump complete
--

