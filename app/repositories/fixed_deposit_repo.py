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
        self.cursor.execute("SELECT * FROM fixed_deposit_details ORDER BY opened_date DESC")
        return self.cursor.fetchall()

    def create_fd_plan(self, duration_months, interest_rate, created_by_user_id=None):
        """
        Create a new fixed deposit plan.
        """
        self.cursor.execute(
        "SELECT * FROM create_fd_plan(%s, %s, %s::uuid)",
        (duration_months, interest_rate, created_by_user_id)
    )
        result = self.cursor.fetchone()
        self.conn.commit()
        return result

    def get_all_fd_plans(self):
        """
        Get all fixed deposit plans.
        """
        self.cursor.execute(
            """SELECT fd_plan_id, duration, interest_rate, status, created_at, updated_at, created_by, updated_by
            FROM fd_plan
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
        try:
            # Insert new fixed deposit using stored procedure
            # The stored procedure returns: fd_id, fd_account_no, balance, acc_id, opened_date, 
            # maturity_date, fd_plan_id, created_at, updated_at, status, created_by, updated_by
            self.cursor.execute(
                "SELECT * FROM create_fixed_deposit(%s::uuid, %s, %s::uuid, %s::uuid)",
                (acc_id, amount, fd_plan_id, created_by_user_id)
            )
            
            result = self.cursor.fetchone()
            self.conn.commit()
            
            if not result:
                raise ValueError("Failed to create fixed deposit")
            
            return result
        except Exception as e:
            self.conn.rollback()
            raise Exception(f"Database error creating fixed deposit: {str(e)}")

    def get_fixed_deposit_with_details(self, fd_id):
        """
        Get fixed deposit with all related details.
        """
        self.cursor.execute(
        "SELECT * FROM get_fixed_deposit_with_details(%s::uuid)",
        (fd_id,)
    )
        return self.cursor.fetchone()

    def get_fixed_deposit_by_fd_id(self, fd_id):
        """
        Get fixed deposit by FD ID with all details.
        """
        self.cursor.execute(
        "SELECT * FROM get_fixed_deposit_by_fd_id(%s::uuid)",
        (fd_id,)
    )
        return self.cursor.fetchone()

    def get_fixed_deposits_by_savings_account(self, savings_account_no):
        """
        Get all fixed deposits linked to a savings account.
        """
        self.cursor.execute(
        "SELECT * FROM get_fixed_deposits_by_savings_account(%s)",
        (savings_account_no,)
    )
        return self.cursor.fetchall()

    def get_fixed_deposits_by_customer_id(self, customer_id):
        """
        Get all fixed deposits for a customer.
        """
        self.cursor.execute(
        "SELECT * FROM get_fixed_deposits_by_customer_id(%s::uuid)",
        (customer_id,)
    )
        return self.cursor.fetchall()

    def get_fixed_deposit_by_account_number(self, fd_account_no):
        """
        Get fixed deposit by FD account number.
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
                fd.created_at as fd_created_at,
                fd.updated_at as fd_updated_at,
                a.account_no,
                b.name as branch_name,
                fp.duration as plan_duration,
                fp.interest_rate as plan_interest_rate
            FROM fixed_deposit fd
            LEFT JOIN account a ON fd.acc_id = a.acc_id
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
            WHERE fd.fd_account_no = %s""",
            (fd_account_no,)
        )
        return self.cursor.fetchone()

    def get_fd_plan_by_fd_id(self, fd_id):
        """
        Get FD plan details by FD ID.
        """
        self.cursor.execute(
            """SELECT fp.fd_plan_id, fp.duration, fp.interest_rate, fp.status, fp.created_at, fp.updated_at
            FROM fd_plan fp
            JOIN fixed_deposit fd ON fp.fd_plan_id = fd.fd_plan_id
            WHERE fd.fd_id = %s""",
            (fd_id,)
        )
        return self.cursor.fetchone()

    def get_fd_plan_by_id(self, fd_plan_id):
        """
        Get FD plan by plan ID.
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
        Update FD plan status.
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

    def get_savings_account_by_fd_number(self, fd_account_no):
        """
        Get savings account details by FD account number.
        """
        self.cursor.execute(
            """SELECT a.acc_id, a.account_no, a.balance, a.opened_date, a.status, b.name as branch_name
            FROM account a
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            JOIN fixed_deposit fd ON a.acc_id = fd.acc_id
            WHERE fd.fd_account_no = %s""",
            (fd_account_no,)
        )
        return self.cursor.fetchone()

    def get_owner_by_fd_number(self, fd_account_no):
        """
        Get customer (owner) details by FD account number.
        """
        self.cursor.execute(
            """SELECT c.customer_id, c.full_name, c.address, c.phone_number, c.nic, c.dob
            FROM customer c
            JOIN accounts_owner ao ON c.customer_id = ao.customer_id
            JOIN account a ON ao.acc_id = a.acc_id
            JOIN fixed_deposit fd ON a.acc_id = fd.acc_id
            WHERE fd.fd_account_no = %s""",
            (fd_account_no,)
        )
        return self.cursor.fetchone()

    def get_branch_by_fd_number(self, fd_account_no):
        """
        Get branch details by FD account number.
        """
        self.cursor.execute(
            """SELECT b.branch_id, b.name, b.address
            FROM branch b
            JOIN account a ON b.branch_id = a.branch_id
            JOIN fixed_deposit fd ON a.acc_id = fd.acc_id
            WHERE fd.fd_account_no = %s""",
            (fd_account_no,)
        )
        return self.cursor.fetchone()

    def get_fixed_deposits_by_branch(self, branch_id):
        """
        Get all fixed deposits in a branch.
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
                fd.created_at as fd_created_at,
                fd.updated_at as fd_updated_at,
                a.account_no,
                b.name as branch_name,
                fp.duration as plan_duration,
                fp.interest_rate as plan_interest_rate
            FROM fixed_deposit fd
            LEFT JOIN account a ON fd.acc_id = a.acc_id
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
            WHERE b.branch_id = %s
            ORDER BY fd.opened_date DESC""",
            (branch_id,)
        )
        return self.cursor.fetchall()

    def get_active_fd_plans(self):
        """
        Get all active FD plans only.
 
        """
        self.cursor.execute(
            """SELECT * FROM fd_plan
            WHERE status = 'active'
            ORDER BY duration ASC"""
        )
        return self.cursor.fetchall()

    def get_fixed_deposits_by_status(self, status):
        """
        Get all fixed deposits by status.
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
                fd.created_at as fd_created_at,
                fd.updated_at as fd_updated_at,
                a.account_no,
                b.name as branch_name,
                fp.duration as plan_duration,
                fp.interest_rate as plan_interest_rate
            FROM fixed_deposit fd
            LEFT JOIN account a ON fd.acc_id = a.acc_id
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
            WHERE fd.status = %s
            ORDER BY fd.opened_date DESC""",
            (status,)
        )
        return self.cursor.fetchall()

    def get_matured_fixed_deposits(self):
        """
        Get all matured fixed deposits (where maturity_date has passed).
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
                fd.created_at as fd_created_at,
                fd.updated_at as fd_updated_at,
                a.account_no,
                b.name as branch_name,
                fp.duration as plan_duration,
                fp.interest_rate as plan_interest_rate
            FROM fixed_deposit fd
            LEFT JOIN account a ON fd.acc_id = a.acc_id
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
            WHERE fd.maturity_date <= CURRENT_TIMESTAMP AND fd.status = 'active'
            ORDER BY fd.maturity_date DESC"""
        )
        return self.cursor.fetchall()

    def get_fixed_deposits_by_plan_id(self, fd_plan_id):
        """
        Get all fixed deposit accounts for a given FD plan ID.
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
                fd.created_at as fd_created_at,
                fd.updated_at as fd_updated_at,
                a.account_no,
                b.name as branch_name,
                fp.duration as plan_duration,
                fp.interest_rate as plan_interest_rate
            FROM fixed_deposit fd
            LEFT JOIN account a ON fd.acc_id = a.acc_id
            LEFT JOIN branch b ON a.branch_id = b.branch_id
            LEFT JOIN fd_plan fp ON fd.fd_plan_id = fp.fd_plan_id
            WHERE fd.fd_plan_id = %s
            ORDER BY fd.opened_date DESC""",
            (fd_plan_id,)
        )
        return self.cursor.fetchall()