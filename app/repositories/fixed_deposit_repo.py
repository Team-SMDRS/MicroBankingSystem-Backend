# Fixed Deposit repository - Database operations for fixed deposits

from psycopg2.extras import RealDictCursor

class FixedDepositRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_all_fixed_deposits(self):
        """
        Fetch all fixed deposit accounts with related information.
        """
        self.cursor.execute(
            """SELECT 
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
            ORDER BY fd.opened_date DESC"""
        )
        return self.cursor.fetchall()

    def create_fd_plan(self, duration_months, interest_rate, created_by_user_id=None):
        """
        Create a new fixed deposit plan.
        """
        self.cursor.execute(
            """INSERT INTO fd_plan (duration, interest_rate, status, created_by, updated_by)
            VALUES (%s, %s, 'active', %s, %s)
            RETURNING fd_plan_id, duration, interest_rate, status, created_at, updated_at, created_by, updated_by""",
            (duration_months, interest_rate, created_by_user_id, created_by_user_id)
        )
        result = self.cursor.fetchone()
        self.conn.commit()
        return result

    def get_all_fd_plans(self):
        """
        Get all fixed deposit plans.
        """
        self.cursor.execute(
            """SELECT fd_plan_id, duration, interest_rate, status, created_at, updated_at
            FROM fd_plan
            WHERE status = 'active'
            ORDER BY duration ASC"""
        )
        return self.cursor.fetchall()

    def get_savings_account_by_account_no(self, account_no):
        """
        Get savings account details by account number.
        """
        self.cursor.execute(
            """SELECT acc_id, account_no, branch_id, balance, status
            FROM account 
            WHERE account_no = %s AND status = 'active'""",
            (account_no,)
        )
        return self.cursor.fetchone()

    def validate_fd_plan(self, plan_id):
        """
        Validate if FD plan exists and is active.
        """
        self.cursor.execute(
            """SELECT fd_plan_id, duration, interest_rate, status
            FROM fd_plan 
            WHERE fd_plan_id = %s AND status = 'active'""",
            (plan_id,)
        )
        return self.cursor.fetchone()

    def create_fixed_deposit(self, acc_id, amount, fd_plan_id, created_by_user_id=None):
        """
        Create a new fixed deposit account.
        """
        # Calculate maturity date based on plan duration
        self.cursor.execute(
            """SELECT duration FROM fd_plan WHERE fd_plan_id = %s""",
            (fd_plan_id,)
        )
        plan = self.cursor.fetchone()
        
        if not plan:
            raise ValueError("Invalid FD plan")
        
        # Insert new fixed deposit with created_by and updated_by fields
        self.cursor.execute(
            """INSERT INTO fixed_deposit (balance, acc_id, fd_plan_id, maturity_date, status, created_by, updated_by)
            VALUES (%s, %s, %s, CURRENT_TIMESTAMP + INTERVAL '%s months', 'active', %s, %s)
            RETURNING fd_id, fd_account_no, balance, acc_id, opened_date, maturity_date, 
                     fd_plan_id, created_at, updated_at, status, created_by, updated_by""",
            (amount, acc_id, fd_plan_id, plan['duration'], created_by_user_id, created_by_user_id)
        )
        
        result = self.cursor.fetchone()
        self.conn.commit()
        return result

    def get_fixed_deposit_with_details(self, fd_id):
        """
        Get fixed deposit with all related details.
        """
        self.cursor.execute(
            """SELECT 
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
            WHERE fd.fd_id = %s""",
            (fd_id,)
        )
        return self.cursor.fetchone()

    def get_fd_plan_by_id(self, fd_plan_id):
        """
        Get FD plan by ID.
        """
        self.cursor.execute(
            """SELECT fd_plan_id, duration, interest_rate, status, created_at, updated_at, created_by, updated_by
            FROM fd_plan
            WHERE fd_plan_id = %s""",
            (fd_plan_id,)
        )
        return self.cursor.fetchone()

    def update_fd_plan_status(self, fd_plan_id, status, updated_by_user_id=None):
        """
        Update the status of an FD plan.
        """
        self.cursor.execute(
            """UPDATE fd_plan 
            SET status = %s, updated_by = %s, updated_at = CURRENT_TIMESTAMP
            WHERE fd_plan_id = %s
            RETURNING fd_plan_id, duration, interest_rate, status, created_at, updated_at, created_by, updated_by""",
            (status, updated_by_user_id, fd_plan_id)
        )
        result = self.cursor.fetchone()
        self.conn.commit()
        return result
