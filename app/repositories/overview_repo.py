"""Overview repository - Database operations for overview and reports"""

from psycopg2.extras import RealDictCursor
from datetime import datetime
from decimal import Decimal


class OverviewRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    def get_monthly_interest_distribution_by_account_type(self, year: int = None, month: int = None):
        """
        Get monthly interest distribution summary by account type (Savings/Fixed Deposit).
        
        Returns:
            List of dicts with account_type, total_accounts, total_interest, average_interest
        """
        if year is None:
            year = datetime.now().year
        if month is None:
            month = datetime.now().month

        query = """
        SELECT 
            'Savings Account' as account_type,
            COUNT(DISTINCT acc.acc_id) as total_accounts,
            SUM(t.amount) as total_interest,
            AVG(t.amount) as average_interest,
            %s as month,
            %s as year
        FROM transactions t
        JOIN account acc ON t.acc_id = acc.acc_id
        WHERE t.type = 'Interest'
            AND EXTRACT(YEAR FROM t.created_at) = %s
            AND EXTRACT(MONTH FROM t.created_at) = %s
        
        UNION ALL
        
        SELECT 
            'Fixed Deposit Account' as account_type,
            COUNT(DISTINCT fd.fd_id) as total_accounts,
            SUM(t.amount) as total_interest,
            AVG(t.amount) as average_interest,
            %s as month,
            %s as year
        FROM transactions t
        JOIN fixed_deposit fd ON t.acc_id = fd.acc_id
        WHERE t.type = 'Interest'
            AND EXTRACT(YEAR FROM t.created_at) = %s
            AND EXTRACT(MONTH FROM t.created_at) = %s
        ORDER BY account_type;
        """

        self.cursor.execute(query, (month, year, year, month, month, year, year, month))
        return self.cursor.fetchall()

    def get_monthly_interest_by_savings_plan(self, year: int = None, month: int = None):
        """
        Get monthly interest distribution by savings plan.
        
        Returns:
            List of dicts with plan details and interest totals
        """
        if year is None:
            year = datetime.now().year
        if month is None:
            month = datetime.now().month

        query = """
        SELECT 
            sp.plan_name,
            sp.interest_rate,
            COUNT(DISTINCT acc.acc_id) as total_accounts,
            SUM(t.amount) as total_interest,
            AVG(t.amount) as average_interest,
            MAX(t.amount) as max_interest,
            MIN(t.amount) as min_interest,
            %s as month,
            %s as year
        FROM transactions t
        JOIN account acc ON t.acc_id = acc.acc_id
        JOIN savings_plan sp ON acc.savings_plan_id = sp.savings_plan_id
        WHERE t.type = 'Interest'
            AND EXTRACT(YEAR FROM t.created_at) = %s
            AND EXTRACT(MONTH FROM t.created_at) = %s
        GROUP BY sp.savings_plan_id, sp.plan_name, sp.interest_rate
        ORDER BY total_interest DESC;
        """

        self.cursor.execute(query, (month, year, year, month))
        return self.cursor.fetchall()

    def get_monthly_interest_by_fd_plan(self, year: int = None, month: int = None):
        """
        Get monthly interest distribution by fixed deposit plan.
        
        Returns:
            List of dicts with FD plan details and interest totals
        """
        if year is None:
            year = datetime.now().year
        if month is None:
            month = datetime.now().month

        query = """
        SELECT 
            fdp.fd_plan_id,
            CONCAT(fdp.duration, ' months') as plan_duration,
            fdp.interest_rate,
            COUNT(DISTINCT fd.fd_id) as total_accounts,
            SUM(t.amount) as total_interest,
            AVG(t.amount) as average_interest,
            MAX(t.amount) as max_interest,
            MIN(t.amount) as min_interest,
            %s as month,
            %s as year
        FROM transactions t
        JOIN fixed_deposit fd ON t.acc_id = fd.acc_id
        JOIN fd_plan fdp ON fd.fd_plan_id = fdp.fd_plan_id
        WHERE t.type = 'Interest'
            AND EXTRACT(YEAR FROM t.created_at) = %s
            AND EXTRACT(MONTH FROM t.created_at) = %s
        GROUP BY fdp.fd_plan_id, fdp.duration, fdp.interest_rate
        ORDER BY total_interest DESC;
        """

        self.cursor.execute(query, (month, year, year, month))
        return self.cursor.fetchall()

    def get_monthly_transaction_summary(self, year: int = None, month: int = None):
        """
        Get monthly transaction summary by type.
        
        Returns:
            List of dicts with transaction type and statistics
        """
        if year is None:
            year = datetime.now().year
        if month is None:
            month = datetime.now().month

        query = """
        SELECT 
            type,
            COUNT(*) as transaction_count,
            SUM(amount) as total_amount,
            AVG(amount) as average_amount,
            MAX(amount) as max_amount,
            MIN(amount) as min_amount,
            %s as month,
            %s as year
        FROM transactions
        WHERE EXTRACT(YEAR FROM created_at) = %s
            AND EXTRACT(MONTH FROM created_at) = %s
        GROUP BY type
        ORDER BY total_amount DESC;
        """

        self.cursor.execute(query, (month, year, year, month))
        return self.cursor.fetchall()

    def get_branch_wise_interest_distribution(self, year: int = None, month: int = None):
        """
        Get monthly interest distribution by branch.
        
        Returns:
            List of dicts with branch details and interest totals
        """
        if year is None:
            year = datetime.now().year
        if month is None:
            month = datetime.now().month

        query = """
        SELECT 
            b.branch_id,
            b.name as branch_name,
            b.address,
            COUNT(DISTINCT acc.acc_id) as total_accounts,
            SUM(t.amount) as total_interest,
            AVG(t.amount) as average_interest,
            MAX(t.amount) as max_interest,
            MIN(t.amount) as min_interest,
            %s as month,
            %s as year
        FROM transactions t
        JOIN account acc ON t.acc_id = acc.acc_id
        JOIN branch b ON acc.branch_id = b.branch_id
        WHERE t.type = 'Interest'
            AND EXTRACT(YEAR FROM t.created_at) = %s
            AND EXTRACT(MONTH FROM t.created_at) = %s
        GROUP BY b.branch_id, b.name, b.address
        ORDER BY total_interest DESC;
        """

        self.cursor.execute(query, (month, year, year, month))
        return self.cursor.fetchall()
