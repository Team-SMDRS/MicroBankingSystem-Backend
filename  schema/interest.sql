-- Calculate average daily balance and daily interest for each account on 2025-10-05
-- Assuming interest is calculated based on the average daily balance and the interest rate from the savings_plan table

WITH tx AS (
    SELECT
        acc_id,
        type,
        amount,
        created_at
    FROM public.transactions
    WHERE acc_id IN (
        SELECT acc_id 
        FROM public.account
    )
      AND DATE(created_at) = '2025-10-05'
),
opening_balance AS (
    SELECT 
        a.acc_id,
        a.balance 
        - COALESCE(SUM(
            CASE 
                WHEN t.type IN ('Deposit', 'BankTransfer-In') THEN t.amount
                WHEN t.type IN ('Withdrawal', 'BankTransfer-Out') THEN -t.amount
                ELSE 0
            END
        ), 0) AS opening_balance
    FROM public.account a
    LEFT JOIN tx t ON a.acc_id = t.acc_id
    GROUP BY a.acc_id, a.balance
),
ordered_tx AS (
    SELECT
        acc_id,
        type,
        amount,
        created_at,
        LAG(created_at) OVER (PARTITION BY acc_id ORDER BY created_at) AS prev_time
    FROM tx
),
balance_timeline AS (
    SELECT
        acc_id,
        created_at,
        type,
        amount,
        EXTRACT(EPOCH FROM (created_at - COALESCE(prev_time, DATE_TRUNC('day', created_at)))) AS seconds_elapsed
    FROM ordered_tx
),
signed_tx AS (
    SELECT
        acc_id,
        created_at,
        CASE 
            WHEN type IN ('Deposit', 'BankTransfer-In') THEN amount
            WHEN type IN ('Withdrawal', 'BankTransfer-Out') THEN -amount
            ELSE 0
        END AS net_amount,
        seconds_elapsed
    FROM balance_timeline
),
weighted_balance AS (
    SELECT
        ob.acc_id,
        (
            ob.opening_balance * 86400
            + COALESCE(SUM(st.net_amount * st.seconds_elapsed), 0)  -- <- handle no transactions
        ) / 86400 AS avg_balance
    FROM opening_balance ob
    LEFT JOIN signed_tx st ON ob.acc_id = st.acc_id
    GROUP BY ob.acc_id, ob.opening_balance
)
SELECT
    w.acc_id,
    ROUND(w.avg_balance::numeric, 2) AS avg_balance,
    sp.interest_rate,
    ROUND(GREATEST(w.avg_balance, 0) * (sp.interest_rate / 100) / 365, 4) AS daily_interest
FROM weighted_balance w
JOIN public.account a ON w.acc_id = a.acc_id
JOIN public.savings_plan sp ON a.savings_plan_id = sp.savings_plan_id;










-- Calculate total interest for each account for the month of October 2025 

WITH days AS (
    SELECT generate_series('2025-10-01'::date, '2025-10-31'::date, interval '1 day') AS day
),
tx AS (
    SELECT
        acc_id,
        type,
        amount,
        created_at::date AS tx_date,
        created_at
    FROM public.transactions
    WHERE created_at >= '2025-10-01'::date
      AND created_at < '2025-11-01'::date
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
    GROUP BY a.acc_id, d.day, a.balance
),
-- now calculate weighted avg per day using the same logic as before
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
),
daily_interest AS (
    SELECT
        w.acc_id,
        w.day,
        sp.interest_rate,
        GREATEST(w.avg_balance,0) * sp.interest_rate / (100*365) AS interest
    FROM weighted_daily w
    JOIN public.account a ON w.acc_id = a.acc_id
    JOIN public.savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
)
SELECT
    acc_id,
    SUM(interest) AS monthly_interest
FROM daily_interest
GROUP BY acc_id
ORDER BY acc_id;






-- Generalized version to calculate total interest for each account for the previous month

WITH prev_month AS (
    SELECT 
        date_trunc('month', current_date) - interval '1 month' AS start_date,
        date_trunc('month', current_date) - interval '1 day' AS end_date
),
days AS (
    SELECT generate_series(
        start_date::date,
        end_date::date,
        interval '1 day'
    ) AS day
    FROM prev_month
),
tx AS (
    SELECT
        acc_id,
        type,
        amount,
        created_at::date AS tx_date,
        created_at
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
),
daily_interest AS (
    SELECT
        w.acc_id,
        w.day,
        sp.interest_rate,
        GREATEST(w.avg_balance,0) * sp.interest_rate / (100*365) AS interest
    FROM weighted_daily w
    JOIN public.account a ON w.acc_id = a.acc_id
    JOIN public.savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
)
SELECT
    acc_id,
    SUM(interest) AS monthly_interest
FROM daily_interest
GROUP BY acc_id
ORDER BY acc_id;












-- Generalized version to calculate total interest for each account for the previous month

CREATE OR REPLACE FUNCTION calculate_monthly_interest()
RETURNS void AS
$$
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
    SELECT w.acc_id, SUM(GREATEST(w.avg_balance,0) * sp.interest_rate / (100*365)) AS interest
    FROM weighted_daily w
    JOIN public.account a ON w.acc_id = a.acc_id
    JOIN public.savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
    GROUP BY w.acc_id;

    -- Step 2: Insert interest transactions
    INSERT INTO public.transactions (amount, acc_id, type, description, created_at, created_by)
    SELECT interest, acc_id, 'Interest', 'Monthly interest', v_now, '839c9a79-9f0a-4ba7-9d4c-91358f9b93b1'
    FROM temp_monthly_interest;

    -- Step 3: Update account balances
    UPDATE public.account a
    SET balance = a.balance + tmi.interest
    FROM temp_monthly_interest tmi
    WHERE a.acc_id = tmi.acc_id;

    -- Step 4: Drop temp table
    DROP TABLE temp_monthly_interest;

END;
$$
LANGUAGE plpgsql;


CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'monthly_interest_job',  -- job name
    '5 0 1 * *',             -- first day of every month at 00:05
    $$
    SELECT calculate_monthly_interest();
    $$
);
