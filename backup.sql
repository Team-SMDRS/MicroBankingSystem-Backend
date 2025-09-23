--
-- PostgreSQL database dump
--

-- Dumped from database version 17.5
-- Dumped by pg_dump version 17.5

-- Started on 2025-09-20 19:02:57 +0530

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
-- TOC entry 3714 (class 1262 OID 17772)
-- Name: bankdata; Type: DATABASE; Schema: -; Owner: -
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
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- TOC entry 3715 (class 0 OID 0)
-- Dependencies: 6
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- TOC entry 2 (class 3079 OID 25566)
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- TOC entry 3716 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- TOC entry 953 (class 1247 OID 25912)
-- Name: audit_action; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.audit_action AS ENUM (
    'INSERT',
    'UPDATE',
    'DELETE'
);


--
-- TOC entry 929 (class 1247 OID 25780)
-- Name: transaction_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.transaction_type AS ENUM (
    'Deposit',
    'Withdrawal',
    'Interest',
    'BankTransfer'
);


--
-- TOC entry 236 (class 1255 OID 26833)
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
-- TOC entry 286 (class 1255 OID 25954)
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
-- TOC entry 235 (class 1255 OID 25987)
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
-- TOC entry 248 (class 1255 OID 26831)
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
-- TOC entry 249 (class 1255 OID 26832)
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
-- TOC entry 287 (class 1255 OID 25955)
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 224 (class 1259 OID 25719)
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    acc_id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_no character varying(20),
    branch_id uuid,
    savings_plan_id uuid,
    balance numeric(24,12),
    opened_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid
);


--
-- TOC entry 232 (class 1259 OID 25896)
-- Name: accounts_owner; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts_owner (
    acc_id uuid NOT NULL,
    customer_id uuid NOT NULL
);


--
-- TOC entry 233 (class 1259 OID 25919)
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
-- TOC entry 221 (class 1259 OID 25665)
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
-- TOC entry 229 (class 1259 OID 25831)
-- Name: customer; Type: TABLE; Schema: public; Owner: -
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


--
-- TOC entry 230 (class 1259 OID 25851)
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
-- TOC entry 222 (class 1259 OID 25683)
-- Name: fd_plan; Type: TABLE; Schema: public; Owner: -
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


--
-- TOC entry 225 (class 1259 OID 25750)
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
    updated_by uuid
);


--
-- TOC entry 220 (class 1259 OID 25653)
-- Name: login; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login (
    log_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    login_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- TOC entry 227 (class 1259 OID 25808)
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role (
    role_id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_name character varying(50) NOT NULL
);


--
-- TOC entry 223 (class 1259 OID 25701)
-- Name: savings_plan; Type: TABLE; Schema: public; Owner: -
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


--
-- TOC entry 226 (class 1259 OID 25789)
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
-- TOC entry 219 (class 1259 OID 25623)
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
    updated_by uuid
);


--
-- TOC entry 234 (class 1259 OID 25933)
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
-- TOC entry 218 (class 1259 OID 25603)
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
    updated_by uuid
);


--
-- TOC entry 231 (class 1259 OID 25881)
-- Name: users_branch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_branch (
    user_id uuid NOT NULL,
    branch_id uuid NOT NULL
);


--
-- TOC entry 228 (class 1259 OID 25816)
-- Name: users_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_role (
    user_id uuid NOT NULL,
    role_id uuid NOT NULL
);


--
-- TOC entry 3698 (class 0 OID 25719)
-- Dependencies: 224
-- Data for Name: account; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.account VALUES ('1b337986-ae2d-4e9e-9f87-5bd92e29253f', '1234567890', '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 1000.000000000000, '2025-09-18 13:56:05.448161', '2025-09-18 13:56:05.448161', '2025-09-18 14:07:15.810099', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');
INSERT INTO public.account VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', '0123456789', '57438d7f-184f-42fe-b0d6-91a2ef609beb', '7d8f328d-650d-4e19-b2ef-4c7292f6264a', 2000.000000000000, '2025-09-18 14:07:15.807623', '2025-09-18 14:07:15.807623', '2025-09-18 14:26:16.479309', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09');
INSERT INTO public.account VALUES ('3337ad45-7e90-4c8f-9057-e38f3c43f196', '1111111111', '3dd6870c-e6f2-414d-9973-309ba00ce115', '3578bd55-8c57-4757-aa7b-0f37b859edd6', 3000.000000000000, '2025-09-18 14:43:34.844831', '2025-09-18 14:43:34.844831', '2025-09-18 14:43:34.844831', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');


--
-- TOC entry 3706 (class 0 OID 25896)
-- Dependencies: 232
-- Data for Name: accounts_owner; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.accounts_owner VALUES ('1b337986-ae2d-4e9e-9f87-5bd92e29253f', '12d17661-847d-4385-9fd2-ea582da813b2');
INSERT INTO public.accounts_owner VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', '96a6ea17-b2d3-40d0-9c5b-903da6280f50');
INSERT INTO public.accounts_owner VALUES ('fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'f0bf0ef8-0015-4c79-bae4-bab26d897409');
INSERT INTO public.accounts_owner VALUES ('3337ad45-7e90-4c8f-9057-e38f3c43f196', '97da5431-f39a-43e5-b0cd-9d185327b6e6');


--
-- TOC entry 3707 (class 0 OID 25919)
-- Dependencies: 233
-- Data for Name: audit_log; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.audit_log VALUES ('e725be3d-ade7-4881-ab46-2dceae2bdad8', 'users', 'de9dc531-11bf-4481-882a-dc3291580f60', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-09-18 07:09:21.535303');
INSERT INTO public.audit_log VALUES ('cd24de61-14f1-4914-a477-51dcfd564c21', 'users', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 07:19:23.418837');
INSERT INTO public.audit_log VALUES ('b85bcf9b-0083-4f87-b74d-f436f210439a', 'users', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 14:04:14.712609');
INSERT INTO public.audit_log VALUES ('2469da8a-bac2-4709-9294-cbc8a8f6426c', 'users', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'INSERT', NULL, '{nic,first_name,last_name,address,phone_number,dob,created_by}', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 14:18:45.238594');


--
-- TOC entry 3695 (class 0 OID 25665)
-- Dependencies: 221
-- Data for Name: branch; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.branch VALUES ('3dd6870c-e6f2-414d-9973-309ba00ce115', 'Colombo', 'colombo', '2025-09-18 07:05:43.839001', '2025-09-18 07:05:43.839001', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1');
INSERT INTO public.branch VALUES ('57438d7f-184f-42fe-b0d6-91a2ef609beb', 'Jafna', 'Jafna', '2025-09-18 07:07:02.375386', '2025-09-18 07:07:02.375386', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1');


--
-- TOC entry 3703 (class 0 OID 25831)
-- Dependencies: 229
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.customer VALUES ('12d17661-847d-4385-9fd2-ea582da813b2', 'customer 3', 'colombo', '0745879866', '200147897589', '2025-09-18 14:33:26.650656', '2025-09-18 14:33:26.650656', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-02-06');
INSERT INTO public.customer VALUES ('96a6ea17-b2d3-40d0-9c5b-903da6280f50', 'customer 1', 'jafna', '0724548799', '200454546545', '2025-09-18 14:29:18.039149', '2025-09-18 14:33:26.652769', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-02-06');
INSERT INTO public.customer VALUES ('f0bf0ef8-0015-4c79-bae4-bab26d897409', 'customer 2', 'jafna', '0756548799', '200725457898', '2025-09-18 14:29:55.137535', '2025-09-18 14:33:26.654507', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '2001-02-06');
INSERT INTO public.customer VALUES ('97da5431-f39a-43e5-b0cd-9d185327b6e6', 'customer 4', 'colombo', '0144545466', '211454546587', '2025-09-18 14:41:28.403699', '2025-09-18 14:41:28.403699', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '2001-02-06');


--
-- TOC entry 3704 (class 0 OID 25851)
-- Dependencies: 230
-- Data for Name: customer_login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.customer_login VALUES ('657f315a-9b6a-4c54-a3d1-b72fa645c7f5', '97da5431-f39a-43e5-b0cd-9d185327b6e6', 'mycustomer', '$2a$12$7gXkpFQmcoCPFx39ssSJb.FcJNK8opQzlLU5z5XcoYJEpcKZjWthm', '2025-09-19 02:18:40.386038', '2025-09-19 02:18:40.386038', '2025-09-19 02:18:40.386038', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');


--
-- TOC entry 3696 (class 0 OID 25683)
-- Dependencies: 222
-- Data for Name: fd_plan; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fd_plan VALUES ('aba51ea9-6174-4a6e-8463-6d03dd717185', 6, 13.00, '2025-09-18 13:37:13.902794', '2025-09-18 13:37:13.902794', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.fd_plan VALUES ('f6248a43-7311-4741-bf69-9e3628df3cee', 12, 14.00, '2025-09-18 13:37:13.906323', '2025-09-18 13:37:13.906323', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.fd_plan VALUES ('fede8a9f-d3a5-4aee-a763-e43eae84397f', 36, 15.00, '2025-09-18 13:37:13.907726', '2025-09-18 13:37:13.907726', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');


--
-- TOC entry 3699 (class 0 OID 25750)
-- Dependencies: 225
-- Data for Name: fixed_deposit; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fixed_deposit VALUES ('11b6d2ad-ce98-48e2-a70f-0660d84247d0', 20000.000000000000, '3337ad45-7e90-4c8f-9057-e38f3c43f196', '2025-09-18 15:06:34.963377', '2026-03-18 15:06:34.963', 'aba51ea9-6174-4a6e-8463-6d03dd717185', '2025-09-18 15:06:34.963377', '2025-09-18 15:07:06.178408', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', '6b997217-9ce5-4dda-a9ae-87bf589b92a5');


--
-- TOC entry 3694 (class 0 OID 25653)
-- Dependencies: 220
-- Data for Name: login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.login VALUES ('ef0de396-9787-4c94-81b4-14b1e087fb51', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2025-09-18 07:01:09.926708');
INSERT INTO public.login VALUES ('97ac0c3a-f003-4f92-bae1-edce2a4b7406', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 07:18:25.922307');
INSERT INTO public.login VALUES ('7f26152e-ee50-4ea2-add4-5042e703a9f3', 'de9dc531-11bf-4481-882a-dc3291580f60', '2025-09-18 14:02:15.673806');


--
-- TOC entry 3701 (class 0 OID 25808)
-- Dependencies: 227
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.role VALUES ('88e07160-2df2-4d18-ab38-9b4668267956', 'admin');
INSERT INTO public.role VALUES ('1f65261b-a275-4b10-a71d-a556f3525428', 'manager');


--
-- TOC entry 3697 (class 0 OID 25701)
-- Dependencies: 223
-- Data for Name: savings_plan; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.savings_plan VALUES ('3578bd55-8c57-4757-aa7b-0f37b859edd6', 'Adult', 10.00, '2025-09-18 10:25:36.776016', '2025-09-18 10:25:36.776016', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.savings_plan VALUES ('7d8f328d-650d-4e19-b2ef-4c7292f6264a', 'Joint', 7.00, '2025-09-18 10:27:13.250715', '2025-09-18 10:27:13.250715', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.savings_plan VALUES ('75cb0dfb-be48-4b4c-ab13-9e01772f0332', 'Children', 12.00, '2025-09-18 13:35:04.860764', '2025-09-18 13:35:04.860764', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');


--
-- TOC entry 3700 (class 0 OID 25789)
-- Dependencies: 226
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.transactions VALUES ('4d7972d3-31fc-4795-b42a-efec9c31303e', 100.00, 'fb7b432f-634b-4b7c-9ee5-f4ba4a38f531', 'Deposit', 'damma', '2025-09-18 15:10:00.830901', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 141111295237170);


--
-- TOC entry 3693 (class 0 OID 25623)
-- Dependencies: 219
-- Data for Name: user_login; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.user_login VALUES ('9fdc2462-7532-40da-82d0-2b8a6aad1128', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', 'system1', '$2y$10$2tcVhTKEJ4NRts4lmw5NqOxqhCvQQ94sXMraIyK1YqWZw2Zga9vJW', '2025-09-18 06:59:15.461996', '2025-09-18 06:59:15.461996', '2025-09-18 06:59:15.461996', NULL, NULL);
INSERT INTO public.user_login VALUES ('e9ae406d-cb5b-4e8a-ad05-8f955f2b01cd', 'de9dc531-11bf-4481-882a-dc3291580f60', 'user1', '$2b$12$3FeUn7kyl4KDB/Yc2w2uUe4wC2OOpRi5bLskalPsihcZ7K2/wRe0K', '2025-09-18 07:09:21.535303', '2025-09-18 07:09:21.535303', '2025-09-18 07:09:21.535303', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1');
INSERT INTO public.user_login VALUES ('8e940780-67c7-42e8-a307-4a92664ab72f', '6b997217-9ce5-4dda-a9ae-87bf589b92a5', 'user2', '$2b$12$bSFckspDwP6xitca5lzn1.NiWT8qK3Q5nZ5HpD7YsPMP7ky5.7re.', '2025-09-18 07:19:23.418837', '2025-09-18 07:19:23.418837', '2025-09-18 07:19:23.418837', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.user_login VALUES ('e67ce6c6-bb0d-46cf-a222-860e548822a0', '780ba9d3-3c4d-40d6-b1a1-c0132f89df09', 'user3', '$2b$12$w8czX6DDYjBiJvdIjOpxVOatGl32Ca4nX40N9A2fWvsPjPTltraB6', '2025-09-18 14:04:14.712609', '2025-09-18 14:04:14.712609', '2025-09-18 14:04:14.712609', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.user_login VALUES ('86295c07-2139-4499-9410-d729b012cfb7', '75cf1bda-3240-41c5-8235-5a0f06d51fa7', 'user4', '$2b$12$K4ZpGK2cPR0kivNqhtVRzO6vkOSkFKOkx/zNiAKuREJEqVu.BQ.y2', '2025-09-18 14:18:45.238594', '2025-09-18 14:18:45.238594', '2025-09-18 14:18:45.238594', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');


--
-- TOC entry 3708 (class 0 OID 25933)
-- Dependencies: 234
-- Data for Name: user_refresh_tokens; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.user_refresh_tokens VALUES ('678d5f69-4663-47e8-bea8-eb083701dcbb', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '2c5ed2099841278465300796097605bd7bf4da5a214a01e2ae08325b458990e1', '2025-09-25 01:31:09.924771', false, NULL, NULL, '2025-09-18 07:01:09.83433', '2025-09-18 07:01:09.83433', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('e97ab5ee-d733-40d9-adb2-60769303db42', 'de9dc531-11bf-4481-882a-dc3291580f60', 'd63c15766ca38fb841e756e319dfe492e32685c496ebcd232514547aea65f97f', '2025-09-25 01:48:25.920403', false, NULL, NULL, '2025-09-18 07:18:25.687636', '2025-09-18 07:18:25.687636', NULL, NULL);
INSERT INTO public.user_refresh_tokens VALUES ('d278e2a6-75be-4022-a759-13b93a800452', 'de9dc531-11bf-4481-882a-dc3291580f60', 'dbea4ade6837a2361f4e00caea0b70457f8d213ca1576a2356ffc5ae85090017', '2025-09-25 08:32:15.671082', false, NULL, NULL, '2025-09-18 14:02:15.403076', '2025-09-18 14:02:15.403076', NULL, NULL);


--
-- TOC entry 3692 (class 0 OID 25603)
-- Dependencies: 218
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users VALUES ('839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', NULL, 'System ', 'main', NULL, NULL, NULL, '2025-09-18 06:57:17.48252', '2025-09-18 06:57:17.48252', NULL, NULL);
INSERT INTO public.users VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '200325314526', 'user1', 'user1', 'user 1  address', '0765898755', '2003-01-01', '2025-09-18 07:09:21.535303', '2025-09-18 07:09:21.535303', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1', '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1');
INSERT INTO public.users VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '200325314527', 'user2', 'user2', 'user 2  address', '0765898745', '2003-01-01', '2025-09-18 07:19:23.418837', '2025-09-18 07:21:06.077114', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.users VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '200135645879', 'user3', 'user3', 'jafna', '045789866', '2004-10-10', '2025-09-18 14:04:14.712609', '2025-09-18 14:04:14.712609', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');
INSERT INTO public.users VALUES ('75cf1bda-3240-41c5-8235-5a0f06d51fa7', '200135645870', 'user4', 'user4', 'jafna', '045789866', '2004-10-10', '2025-09-18 14:18:45.238594', '2025-09-18 14:18:45.238594', 'de9dc531-11bf-4481-882a-dc3291580f60', 'de9dc531-11bf-4481-882a-dc3291580f60');


--
-- TOC entry 3705 (class 0 OID 25881)
-- Dependencies: 231
-- Data for Name: users_branch; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users_branch VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '3dd6870c-e6f2-414d-9973-309ba00ce115');
INSERT INTO public.users_branch VALUES ('780ba9d3-3c4d-40d6-b1a1-c0132f89df09', '57438d7f-184f-42fe-b0d6-91a2ef609beb');


--
-- TOC entry 3702 (class 0 OID 25816)
-- Dependencies: 228
-- Data for Name: users_role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.users_role VALUES ('de9dc531-11bf-4481-882a-dc3291580f60', '88e07160-2df2-4d18-ab38-9b4668267956');
INSERT INTO public.users_role VALUES ('6b997217-9ce5-4dda-a9ae-87bf589b92a5', '1f65261b-a275-4b10-a71d-a556f3525428');


--
-- TOC entry 3452 (class 2606 OID 25729)
-- Name: account account_account_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_account_no_key UNIQUE (account_no);


--
-- TOC entry 3454 (class 2606 OID 25727)
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (acc_id);


--
-- TOC entry 3487 (class 2606 OID 25900)
-- Name: accounts_owner accounts_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_pkey PRIMARY KEY (acc_id, customer_id);


--
-- TOC entry 3489 (class 2606 OID 25927)
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id);


--
-- TOC entry 3446 (class 2606 OID 25672)
-- Name: branch branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_pkey PRIMARY KEY (branch_id);


--
-- TOC entry 3479 (class 2606 OID 25863)
-- Name: customer_login customer_login_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_key UNIQUE (customer_id);


--
-- TOC entry 3481 (class 2606 OID 25861)
-- Name: customer_login customer_login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3483 (class 2606 OID 25865)
-- Name: customer_login customer_login_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_username_key UNIQUE (username);


--
-- TOC entry 3473 (class 2606 OID 25840)
-- Name: customer customer_nic_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_nic_key UNIQUE (nic);


--
-- TOC entry 3475 (class 2606 OID 25838)
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- TOC entry 3448 (class 2606 OID 25690)
-- Name: fd_plan fd_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_pkey PRIMARY KEY (fd_plan_id);


--
-- TOC entry 3458 (class 2606 OID 25758)
-- Name: fixed_deposit fixed_deposit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_pkey PRIMARY KEY (fd_id);


--
-- TOC entry 3444 (class 2606 OID 25659)
-- Name: login login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_pkey PRIMARY KEY (log_id);


--
-- TOC entry 3467 (class 2606 OID 25813)
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (role_id);


--
-- TOC entry 3469 (class 2606 OID 25815)
-- Name: role role_role_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_role_name_key UNIQUE (role_name);


--
-- TOC entry 3450 (class 2606 OID 25708)
-- Name: savings_plan savings_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_pkey PRIMARY KEY (savings_plan_id);


--
-- TOC entry 3463 (class 2606 OID 25797)
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (transaction_id);


--
-- TOC entry 3465 (class 2606 OID 26839)
-- Name: transactions transactions_reference_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_reference_no_key UNIQUE (reference_no);


--
-- TOC entry 3436 (class 2606 OID 25633)
-- Name: user_login user_login_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_pkey PRIMARY KEY (login_id);


--
-- TOC entry 3438 (class 2606 OID 25635)
-- Name: user_login user_login_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_key UNIQUE (user_id);


--
-- TOC entry 3440 (class 2606 OID 25637)
-- Name: user_login user_login_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_username_key UNIQUE (username);


--
-- TOC entry 3498 (class 2606 OID 25943)
-- Name: user_refresh_tokens user_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_pkey PRIMARY KEY (token_id);


--
-- TOC entry 3485 (class 2606 OID 25885)
-- Name: users_branch users_branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_pkey PRIMARY KEY (user_id, branch_id);


--
-- TOC entry 3432 (class 2606 OID 25612)
-- Name: users users_nic_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_nic_key UNIQUE (nic);


--
-- TOC entry 3434 (class 2606 OID 25610)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- TOC entry 3471 (class 2606 OID 25820)
-- Name: users_role users_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_pkey PRIMARY KEY (user_id, role_id);


--
-- TOC entry 3455 (class 1259 OID 25970)
-- Name: idx_account_account_no; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_account_no ON public.account USING btree (account_no);


--
-- TOC entry 3456 (class 1259 OID 25971)
-- Name: idx_account_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_branch_id ON public.account USING btree (branch_id);


--
-- TOC entry 3490 (class 1259 OID 25975)
-- Name: idx_audit_log_table_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_table_record ON public.audit_log USING btree (table_name, record_id);


--
-- TOC entry 3491 (class 1259 OID 25976)
-- Name: idx_audit_log_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_timestamp ON public.audit_log USING btree ("timestamp");


--
-- TOC entry 3492 (class 1259 OID 25977)
-- Name: idx_audit_log_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_user_id ON public.audit_log USING btree (user_id);


--
-- TOC entry 3476 (class 1259 OID 25969)
-- Name: idx_customer_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_created_at ON public.customer USING btree (created_at);


--
-- TOC entry 3477 (class 1259 OID 25968)
-- Name: idx_customer_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_nic ON public.customer USING btree (nic);


--
-- TOC entry 3441 (class 1259 OID 25979)
-- Name: idx_login_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_time ON public.login USING btree (login_time);


--
-- TOC entry 3442 (class 1259 OID 25978)
-- Name: idx_login_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_user_id ON public.login USING btree (user_id);


--
-- TOC entry 3459 (class 1259 OID 25972)
-- Name: idx_transactions_acc_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_acc_id ON public.transactions USING btree (acc_id);


--
-- TOC entry 3460 (class 1259 OID 25973)
-- Name: idx_transactions_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at);


--
-- TOC entry 3461 (class 1259 OID 25974)
-- Name: idx_transactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_type ON public.transactions USING btree (type);


--
-- TOC entry 3493 (class 1259 OID 25983)
-- Name: idx_user_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_expires_at ON public.user_refresh_tokens USING btree (expires_at);


--
-- TOC entry 3494 (class 1259 OID 25982)
-- Name: idx_user_refresh_tokens_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_hash ON public.user_refresh_tokens USING btree (token_hash);


--
-- TOC entry 3495 (class 1259 OID 25984)
-- Name: idx_user_refresh_tokens_revoked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_revoked ON public.user_refresh_tokens USING btree (is_revoked);


--
-- TOC entry 3496 (class 1259 OID 25981)
-- Name: idx_user_refresh_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_user_id ON public.user_refresh_tokens USING btree (user_id);


--
-- TOC entry 3429 (class 1259 OID 25967)
-- Name: idx_users_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_created_at ON public.users USING btree (created_at);


--
-- TOC entry 3430 (class 1259 OID 25966)
-- Name: idx_users_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_nic ON public.users USING btree (nic);


--
-- TOC entry 3541 (class 2620 OID 25961)
-- Name: account update_account_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_account_updated_at BEFORE UPDATE ON public.account FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3538 (class 2620 OID 25958)
-- Name: branch update_branch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_branch_updated_at BEFORE UPDATE ON public.branch FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3545 (class 2620 OID 25965)
-- Name: customer_login update_customer_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_login_updated_at BEFORE UPDATE ON public.customer_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3544 (class 2620 OID 25964)
-- Name: customer update_customer_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_updated_at BEFORE UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3539 (class 2620 OID 25959)
-- Name: fd_plan update_fd_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fd_plan_updated_at BEFORE UPDATE ON public.fd_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3542 (class 2620 OID 25962)
-- Name: fixed_deposit update_fixed_deposit_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fixed_deposit_updated_at BEFORE UPDATE ON public.fixed_deposit FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3543 (class 2620 OID 25963)
-- Name: role update_role_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_role_updated_at BEFORE UPDATE ON public.role FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3540 (class 2620 OID 25960)
-- Name: savings_plan update_savings_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_savings_plan_updated_at BEFORE UPDATE ON public.savings_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3536 (class 2620 OID 25957)
-- Name: user_login update_user_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_login_updated_at BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3546 (class 2620 OID 25980)
-- Name: user_refresh_tokens update_user_refresh_tokens_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_refresh_tokens_updated_at BEFORE UPDATE ON public.user_refresh_tokens FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3535 (class 2620 OID 25956)
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3537 (class 2620 OID 26834)
-- Name: user_login user_login_update_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_login_update_audit BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.audit_user_login_update();


--
-- TOC entry 3511 (class 2606 OID 25730)
-- Name: account account_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3512 (class 2606 OID 25740)
-- Name: account account_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3513 (class 2606 OID 25735)
-- Name: account account_savings_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_savings_plan_id_fkey FOREIGN KEY (savings_plan_id) REFERENCES public.savings_plan(savings_plan_id);


--
-- TOC entry 3514 (class 2606 OID 25745)
-- Name: account account_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3530 (class 2606 OID 25901)
-- Name: accounts_owner accounts_owner_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3531 (class 2606 OID 25906)
-- Name: accounts_owner accounts_owner_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts_owner
    ADD CONSTRAINT accounts_owner_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- TOC entry 3532 (class 2606 OID 25928)
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3505 (class 2606 OID 25673)
-- Name: branch branch_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3506 (class 2606 OID 25678)
-- Name: branch branch_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3523 (class 2606 OID 25841)
-- Name: customer customer_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3525 (class 2606 OID 25866)
-- Name: customer_login customer_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3526 (class 2606 OID 25876)
-- Name: customer_login customer_login_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON DELETE CASCADE;


--
-- TOC entry 3527 (class 2606 OID 25871)
-- Name: customer_login customer_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_login
    ADD CONSTRAINT customer_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3524 (class 2606 OID 25846)
-- Name: customer customer_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3507 (class 2606 OID 25691)
-- Name: fd_plan fd_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3508 (class 2606 OID 25696)
-- Name: fd_plan fd_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fd_plan
    ADD CONSTRAINT fd_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3515 (class 2606 OID 25759)
-- Name: fixed_deposit fixed_deposit_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3516 (class 2606 OID 25769)
-- Name: fixed_deposit fixed_deposit_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3517 (class 2606 OID 25764)
-- Name: fixed_deposit fixed_deposit_fd_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_fd_plan_id_fkey FOREIGN KEY (fd_plan_id) REFERENCES public.fd_plan(fd_plan_id);


--
-- TOC entry 3518 (class 2606 OID 25774)
-- Name: fixed_deposit fixed_deposit_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit
    ADD CONSTRAINT fixed_deposit_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3504 (class 2606 OID 25660)
-- Name: login login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login
    ADD CONSTRAINT login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3509 (class 2606 OID 25709)
-- Name: savings_plan savings_plan_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3510 (class 2606 OID 25714)
-- Name: savings_plan savings_plan_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_plan
    ADD CONSTRAINT savings_plan_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3519 (class 2606 OID 25798)
-- Name: transactions transactions_acc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_acc_id_fkey FOREIGN KEY (acc_id) REFERENCES public.account(acc_id);


--
-- TOC entry 3520 (class 2606 OID 25803)
-- Name: transactions transactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3501 (class 2606 OID 25638)
-- Name: user_login user_login_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3502 (class 2606 OID 25643)
-- Name: user_login user_login_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- TOC entry 3503 (class 2606 OID 25648)
-- Name: user_login user_login_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_login
    ADD CONSTRAINT user_login_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- TOC entry 3533 (class 2606 OID 25944)
-- Name: user_refresh_tokens user_refresh_tokens_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES public.users(user_id);


--
-- TOC entry 3534 (class 2606 OID 25949)
-- Name: user_refresh_tokens user_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_refresh_tokens
    ADD CONSTRAINT user_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_login(user_id) ON DELETE CASCADE;


--
-- TOC entry 3528 (class 2606 OID 25891)
-- Name: users_branch users_branch_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- TOC entry 3529 (class 2606 OID 25886)
-- Name: users_branch users_branch_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_branch
    ADD CONSTRAINT users_branch_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3499 (class 2606 OID 25613)
-- Name: users users_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- TOC entry 3521 (class 2606 OID 25826)
-- Name: users_role users_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(role_id);


--
-- TOC entry 3522 (class 2606 OID 25821)
-- Name: users_role users_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_role
    ADD CONSTRAINT users_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- TOC entry 3500 (class 2606 OID 25618)
-- Name: users users_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


-- Completed on 2025-09-20 19:02:57 +0530

--
-- PostgreSQL database dump complete
--

