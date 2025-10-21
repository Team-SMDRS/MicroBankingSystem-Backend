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


    def get_branch_overview(self, branch_id: str):
        """Get comprehensive overview of a branch for dashboard visualization."""
        # Branch basic info
        self.cursor.execute(
            "SELECT branch_id, name, address FROM branch WHERE branch_id = %s",
            (branch_id,)
        )
        branch = self.cursor.fetchone()
        if not branch:
            return None

        # Account statistics
        self.cursor.execute("""
            SELECT 
                COUNT(*) as total_accounts,
                COUNT(CASE WHEN status = 'active' THEN 1 END) as active_accounts,
                SUM(balance) as total_balance,
                AVG(balance) as average_balance
            FROM account WHERE branch_id = %s
        """, (branch_id,))
        account_stats = self.cursor.fetchone()

        # Accounts by savings plan (pie chart)
        self.cursor.execute("""
            SELECT 
                sp.plan_name,
                COUNT(a.acc_id) as account_count,
                SUM(a.balance) as total_balance
            FROM account a
            LEFT JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
            WHERE a.branch_id = %s
            GROUP BY sp.plan_name
            ORDER BY account_count DESC
        """, (branch_id,))
        accounts_by_plan = self.cursor.fetchall()

        # Daily transactions (last 30 days)
        self.cursor.execute("""
            SELECT 
                DATE(t.created_at) as transaction_date,
                COUNT(*) as transaction_count,
                SUM(t.amount) as total_amount
            FROM transactions t
            JOIN account a ON t.acc_id = a.acc_id
            WHERE a.branch_id = %s
                AND t.created_at >= CURRENT_DATE - INTERVAL '30 days'
            GROUP BY DATE(t.created_at)
            ORDER BY transaction_date DESC
        """, (branch_id,))
        daily_transactions = self.cursor.fetchall()

        # Transaction types distribution
        self.cursor.execute("""
            SELECT 
                t.type,
                COUNT(*) as transaction_count,
                SUM(t.amount) as total_amount
            FROM transactions t
            JOIN account a ON t.acc_id = a.acc_id
            WHERE a.branch_id = %s
            GROUP BY t.type
            ORDER BY total_amount DESC
        """, (branch_id,))
        transaction_types = self.cursor.fetchall()

        # Account status distribution
        self.cursor.execute("""
            SELECT 
                status,
                COUNT(*) as count,
                SUM(balance) as total_balance
            FROM account WHERE branch_id = %s
            GROUP BY status
        """, (branch_id,))
        account_status = self.cursor.fetchall()

        # Top 10 accounts
        self.cursor.execute("""
            SELECT 
                account_no,
                balance,
                status,
                sp.plan_name
            FROM account a
            LEFT JOIN savings_plan sp ON a.savings_plan_id = sp.savings_plan_id
            WHERE a.branch_id = %s
            ORDER BY balance DESC LIMIT 10
        """, (branch_id,))
        top_accounts = self.cursor.fetchall()

        # Monthly trend
        self.cursor.execute("""
            SELECT 
                EXTRACT(YEAR FROM t.created_at) as year,
                EXTRACT(MONTH FROM t.created_at) as month,
                COUNT(*) as transaction_count,
                SUM(t.amount) as total_amount
            FROM transactions t
            JOIN account a ON t.acc_id = a.acc_id
            WHERE a.branch_id = %s
                AND t.created_at >= CURRENT_DATE - INTERVAL '12 months'
            GROUP BY EXTRACT(YEAR FROM t.created_at), EXTRACT(MONTH FROM t.created_at)
            ORDER BY year DESC, month DESC
        """, (branch_id,))
        monthly_trend = self.cursor.fetchall()

        # Weekly interest
        self.cursor.execute("""
            SELECT 
                DATE_TRUNC('week', t.created_at)::DATE as week_start,
                SUM(t.amount) as total_interest,
                COUNT(*) as interest_count
            FROM transactions t
            JOIN account a ON t.acc_id = a.acc_id
            WHERE a.branch_id = %s
                AND t.type = 'Interest'
                AND t.created_at >= CURRENT_DATE - INTERVAL '8 weeks'
            GROUP BY DATE_TRUNC('week', t.created_at)
            ORDER BY week_start DESC
        """, (branch_id,))
        weekly_interest = self.cursor.fetchall()

        return {
            'branch': branch,
            'account_stats': account_stats,
            'accounts_by_plan': accounts_by_plan,
            'daily_transactions': daily_transactions,
            'transaction_types': transaction_types,
            'account_status': account_status,
            'top_accounts': top_accounts,
            'monthly_trend': monthly_trend,
            'weekly_interest': weekly_interest
        }

    def get_branch_comparison(self):
        """Get comparison data for all branches."""
        self.cursor.execute("""
            SELECT 
                b.branch_id,
                b.name as branch_name,
                COUNT(DISTINCT a.acc_id) as total_accounts,
                COUNT(DISTINCT CASE WHEN a.status = 'active' THEN a.acc_id END) as active_accounts,
                SUM(a.balance) as total_balance,
                COUNT(DISTINCT t.transaction_id) as total_transactions,
                SUM(CASE WHEN t.type = 'Interest' THEN t.amount ELSE 0 END) as total_interest
            FROM branch b
            LEFT JOIN account a ON b.branch_id = a.branch_id
            LEFT JOIN transactions t ON a.acc_id = t.acc_id
            GROUP BY b.branch_id, b.name
            ORDER BY total_balance DESC
        """)
        return self.cursor.fetchall()