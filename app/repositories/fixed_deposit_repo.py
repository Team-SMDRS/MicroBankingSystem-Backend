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
