CREATE TABLE public.daily_interest (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    acc_id uuid NOT NULL REFERENCES public.account(acc_id),
    interest_date date NOT NULL,
    daily_interest numeric(24,12) NOT NULL,
    created_at timestamp DEFAULT CURRENT_TIMESTAMP
);


CREATE OR REPLACE FUNCTION calculate_daily_interest()
RETURNS void AS $$
BEGIN
    INSERT INTO daily_interest (acc_id, interest_date, daily_interest)
    SELECT 
        a.acc_id,
        CURRENT_DATE AS interest_date,
        a.balance * (sp.interest_rate / 100) / 365 AS daily_interest
    FROM account a
    JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
    WHERE a.status = 'active';
END;
$$ LANGUAGE plpgsql;


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
); CREATE TABLE public.transactions (
    transaction_id uuid DEFAULT gen_random_uuid() NOT NULL,
    amount numeric(12,2) NOT NULL,
    acc_id uuid,
    type public.transaction_type NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    reference_no bigint DEFAULT (floor((random() * ('1000000000000000'::numeric)::double precision)))::bigint
);
CREATE TABLE public.savings_plan (
    savings_plan_id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_name character varying(100),
    interest_rate numeric(5,2),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by uuid,
    updated_by uuid
);Project 4 - Microbanking and Interest Management System
B-Trust is a small private microfinance bank operating across several districts in Sri
Lanka. The bank aims to support financial inclusion by offering basic savings products
and fixed deposits, particularly for rural communities. To improve service efficiency, the
bank has decided to digitise its core operations and offer customers the ability to deposit,
withdraw, and monitor their balances through an online system managed by regional
service agents.
Your team has been hired to design the backend database of this Microbanking and
Interest Management System (MIMS). A lightweight UI must be developed to allow QA
testers to interact with the database and validate key operations.
The system requirements are as follows:
• The bank operates a series of service branches, each managing a team of
banking agents.
• Customers can register at any branch and are assigned to a specific agent.
• Each customer can open one or more Savings Accounts, and account holders
may be individuals or joint customers.
• Savings Accounts are offered under different plans:
o Children – 12% interest, no minimum balance
o Teen – 11%, minimum LKR 500
o Adult (18+) – 10%, minimum LKR 1000
o Senior (60+) – 13%, minimum LKR 1000
o Joint – 7%, minimum LKR 5000 , how i calculate each month end,  i have to put all for all accoutts interest , in to transaction table, how i do it ?