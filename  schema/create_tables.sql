
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
    updated_by uuid,
    status public.status_enum DEFAULT 'active'::public.status_enum NOT NULL
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
    updated_by uuid,
    fd_account_no bigint DEFAULT (floor(((random() * (90000000)::double precision) + (10000000)::double precision)))::bigint,
    status public.status_enum DEFAULT 'active'::public.status_enum NOT NULL
);


--
-- TOC entry 235 (class 1259 OID 26909)
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
    fp.interest_rate AS plan_interest_rate
   FROM (((public.fixed_deposit fd
     LEFT JOIN public.account a ON ((fd.acc_id = a.acc_id)))
     LEFT JOIN public.branch b ON ((a.branch_id = b.branch_id)))
     LEFT JOIN public.fd_plan fp ON ((fd.fd_plan_id = fp.fd_plan_id)));


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
    updated_by uuid,
    status public.status_enum DEFAULT 'active'::public.status_enum NOT NULL
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
    updated_by uuid,
    email character varying(100)
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

