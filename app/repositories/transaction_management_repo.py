from psycopg2.extras import RealDictCursor
from typing import List, Optional, Dict, Any, Tuple
from datetime import datetime, date
import uuid
from decimal import Decimal

class TransactionManagementRepository:
    def __init__(self, db_conn):
        self.conn = db_conn
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)

    # Core transaction operations
    def process_deposit_transaction(self, acc_id: str, amount: float, description: str, created_by: str) -> Dict[str, Any]:
        """Process deposit transaction using SQL function with auto-generated transaction_id and reference_no"""
        try:
            self.cursor.execute(
                """
                SELECT * FROM process_deposit_transaction(%s::UUID, %s::NUMERIC, %s::TEXT, %s::UUID)
                """,
                (acc_id, amount, description or f"Deposit of ${amount}", created_by)
            )
            result = self.cursor.fetchone()
            self.conn.commit()
            
            if result:
                return {
                    'transaction_id': str(result.get('transaction_id')),
                    'reference_no': int(result.get('reference_no')) if result.get('reference_no') else None,
                    'new_balance': float(result.get('new_balance') or 0.0),
                    'success': bool(result.get('success', False)),
                }
            return {'success': False, 'error_message': 'No result returned'}

        except Exception as e:
            self.conn.rollback()
            raise e


    def process_withdrawal_transaction(self, acc_id: str, amount: float, description: str, created_by: str) -> Dict[str, Any]:
        """Process withdrawal transaction using SQL function with auto-generated transaction_id and reference_no"""
        try:
            # Call SQL function to process withdrawal (auto-generates transaction_id and reference_no)
            self.cursor.execute(
                """
                SELECT * FROM process_withdrawal_transaction(%s::UUID, %s::NUMERIC, %s::TEXT, %s::UUID)
                """,
                (acc_id, amount, description or f"Withdrawal of ${amount}", created_by)
            )
            result = self.cursor.fetchone()
            self.conn.commit()
            
            if result:
                return {
                    'transaction_id': str(result.get('transaction_id')),
                    'reference_no': int(result.get('reference_no')),
                    'new_balance': float(result.get('new_balance')) if result.get('new_balance') is not None else 0.0,
                    'success': bool(result.get('success', False)),
                    'error_message': result.get('error_message')
                }
            return {'transaction_id': None, 'reference_no': None, 'new_balance': 0, 'success': False, 'error_message': 'No result returned'}
        except Exception as e:
            self.conn.rollback()
            raise e

    def process_transfer_transaction(self, from_acc_id: str, to_acc_id: str, amount: float, description: str, created_by: str) -> Dict[str, Any]:
        """Process money transfer transaction using SQL function with auto-generated transaction_id and reference_no"""
        try:
            # Call SQL function to process transfer (auto-generates transaction_id and reference_no)
            self.cursor.execute("""
    SELECT * FROM process_transfer_transaction(%s::UUID, %s::UUID, %s::NUMERIC, %s::TEXT, %s::UUID)
""", (from_acc_id, to_acc_id, amount, description, created_by))
            result = self.cursor.fetchone()
            self.conn.commit()
            
            if result:
                return {
    'transaction_id': str(result.get('transaction_id')) if result.get('transaction_id') else None,
    'reference_no': int(result.get('reference_no')) if result.get('reference_no') is not None else 0,
    'from_balance': float(result.get('from_balance')) if result.get('from_balance') is not None else 0.0,
    'to_balance': float(result.get('to_balance')) if result.get('to_balance') is not None else 0.0,
    'success': bool(result.get('success')) if result.get('success') is not None else False,
    'error_message': result.get('error_message') or None
}

            return {'transaction_id': None, 'reference_no': None, 'from_balance': 0, 'to_balance': 0, 'success': False, 'error_message': 'No result returned'}
        except Exception as e:
            self.conn.rollback()
            raise e

    # Transaction history and retrieval
    def get_transaction_history_by_account(self, acc_id: str, limit: int = 50, offset: int = 0) -> Tuple[List[Dict], int]:
        """Get transaction history by account using SQL function"""
        try:
            self.cursor.execute(
                """
                SELECT * FROM get_transaction_history_by_account(%s::UUID, %s, %s)
                """,
                (acc_id, limit, offset)
            )
            transactions = self.cursor.fetchall()
            
            # Get total count
            self.cursor.execute(
                """
                SELECT COUNT(*) as count FROM transactions WHERE acc_id = %s::UUID
                """,
                (acc_id,)
            )
            count_result = self.cursor.fetchone()
            total_count = count_result['count'] if count_result else 0
            
            return transactions, total_count
        except Exception as e:
            raise e

    def get_transaction_history_by_date_range(self, start_date: date, end_date: date, acc_id: str = None, transaction_type: str = None) -> List[Dict]:
        """Get transaction history by date range using SQL function"""
        try:
            self.cursor.execute(
                """
                SELECT * FROM get_transaction_history_by_date_range(%s, %s, %s::UUID, %s)
                """,
                (start_date, end_date, acc_id, transaction_type)
            )
            return self.cursor.fetchall()
        except Exception as e:
            raise e

    def get_branch_transaction_report(self, branch_id: str, start_date: date, end_date: date, transaction_type: str = None) -> Dict[str, Any]:
        """Get branch-wise transaction report using SQL function"""
        try:
            self.cursor.execute(
                """
                SELECT * FROM get_branch_transaction_report(%s::UUID, %s, %s, %s)
                """,
                (branch_id, start_date, end_date, transaction_type)
            )
            result = self.cursor.fetchone()
            
            if result:
                return {
                    'branch_id': result.get('branch_id'),
                    'branch_name': result.get('branch_name'),
                    'total_deposits': float(result.get('total_deposits', 0)),
                    'total_withdrawals': float(result.get('total_withdrawals', 0)),
                    'total_transfers': float(result.get('total_transfers', 0)),
                    'transaction_count': result.get('transaction_count', 0)
                }
            return {}
        except Exception as e:
            raise e

    # Transaction summaries and analytics
    def calculate_daily_monthly_transaction_totals(
        self, acc_id: str, period: str, start_date: date = None, end_date: date = None
    ) -> List[Dict]:
        """Calculate daily/monthly transaction totals using SQL function"""
        try:
            self.cursor.execute(
                """
                SELECT * FROM calculate_transaction_totals(%s::UUID, %s, %s, %s)
                """,
                (acc_id, period, start_date, end_date)
            )
            rows = self.cursor.fetchall()
            result = []
            for r in rows:
                result.append({
                    'summary_date': r['summary_date'],
                    'year': r['year'],
                    'month': r['month'],
                    'total_deposits': float(r['total_deposits']),
                    'total_withdrawals': float(r['total_withdrawals']),
                    'total_transfers': float(r['total_transfers']),
                    'transaction_count': r['transaction_count']
                })
            return result
        except Exception as e:
            raise e

    def get_all_transactions_with_account_details(self, limit: int = 100, offset: int = 0) -> List[Dict]:
        """Get all transactions with account details using SQL function"""
        try:
            self.cursor.execute(
                """
                SELECT * FROM get_all_transactions_with_account_details(%s, %s)
                """,
                (limit, offset)
            )
            return self.cursor.fetchall()
        except Exception as e:
            raise e

    # Account operations
    def get_account_balance(self, acc_id: str) -> Optional[float]:
        """Get current account balance"""
        try:
            self.cursor.execute(
                """
                SELECT balance FROM account WHERE acc_id = %s
                """,
                (acc_id,)
            )
            result = self.cursor.fetchone()
            if result and result['balance'] is not None:
                return float(result['balance'])
            return None
        except Exception as e:
            raise e

    def account_exists(self, acc_id: str) -> bool:
        """Check if account exists"""
        try:
            self.cursor.execute(
                """
                SELECT 1 FROM account WHERE acc_id = %s
                """,
                (acc_id,)
            )
            return self.cursor.fetchone() is not None
        except Exception as e:
            raise e

    def get_account_id_by_account_no(self, account_no: int) -> Optional[str]:
        """Get account UUID by account number"""
        try:
            self.cursor.execute(
                """
                SELECT acc_id FROM account WHERE account_no = %s
                """,
                (account_no,)
            )
            result = self.cursor.fetchone()
            return str(result['acc_id']) if result else None
        except Exception as e:
            raise e

    def get_account_with_branch(self, acc_id: str) -> Optional[Dict]:
        """Get account details with branch information"""
        try:
            self.cursor.execute(
                """
                SELECT a.*, b.branch_name, b.branch_code 
                FROM account a 
                LEFT JOIN branch b ON a.branch_id = b.branch_id 
                WHERE a.acc_id = %s
                """,
                (acc_id,)
            )
            return self.cursor.fetchone()
        except Exception as e:
            raise e

    def fix_null_balance(self, acc_id: str) -> bool:
        """Fix NULL balance by setting it to 0.00"""
        try:
            self.cursor.execute(
                """
                UPDATE account SET balance = 0.00 WHERE acc_id = %s AND balance IS NULL
                """,
                (acc_id,)
            )
            self.conn.commit()
            return self.cursor.rowcount > 0
        except Exception as e:
            self.conn.rollback()
            raise e

    # Transaction analytics
    def get_transaction_analytics(self, acc_id: str, days: int = 30) -> Dict[str, Any]:
        """Get transaction analytics for an account"""
        try:
            # Get basic stats
            self.cursor.execute(
                """
                SELECT 
                    COUNT(*) as total_transactions,
                    AVG(amount) as avg_amount,
                    MAX(CASE WHEN type = 'Deposit' THEN amount END) as max_deposit,
                    MAX(CASE WHEN type = 'Withdrawal' THEN amount END) as max_withdrawal,
                    COUNT(CASE WHEN type = 'Deposit' THEN 1 END) as deposit_count,
                    COUNT(CASE WHEN type = 'Withdrawal' THEN 1 END) as withdrawal_count
                FROM transactions 
                WHERE acc_id = %s AND created_at >= CURRENT_DATE - INTERVAL '%s days'
                """,
                (acc_id, days)
            )
            stats = self.cursor.fetchone()
            
            # Get most active day
            self.cursor.execute(
                """
                SELECT DATE(created_at) as transaction_date, COUNT(*) as daily_count
                FROM transactions 
                WHERE acc_id = %s AND created_at >= CURRENT_DATE - INTERVAL '%s days'
                GROUP BY DATE(created_at)
                ORDER BY daily_count DESC
                LIMIT 1
                """,
                (acc_id, days)
            )
            active_day = self.cursor.fetchone()
            
            return {
                'total_transactions': stats.get('total_transactions', 0) if stats else 0,
                'avg_amount': float(stats.get('avg_amount', 0)) if stats and stats.get('avg_amount') else 0,
                'max_deposit': float(stats.get('max_deposit', 0)) if stats and stats.get('max_deposit') else 0,
                'max_withdrawal': float(stats.get('max_withdrawal', 0)) if stats and stats.get('max_withdrawal') else 0,
                'deposit_count': stats.get('deposit_count', 0) if stats else 0,
                'withdrawal_count': stats.get('withdrawal_count', 0) if stats else 0,
                'most_active_date': active_day.get('transaction_date') if active_day else None,
                'most_active_count': active_day.get('daily_count', 0) if active_day else 0
            }
        except Exception as e:
            raise e

    # Utility methods
    def generate_transaction_id(self) -> str:
        """Generate a unique transaction ID as UUID string"""
        return str(uuid.uuid4())

    def generate_reference_number(self) -> int:
        """Generate a unique reference number"""
        import random
        return random.randint(1000000000000000, 9999999999999999)

    def get_transaction_by_id(self, transaction_id: str) -> Optional[Dict]:
        """Get transaction by ID"""
        try:
            self.cursor.execute(
                """
                SELECT t.*, c.full_name as customer_name, a.branch_id
                FROM transactions t
                LEFT JOIN account a ON t.acc_id = a.acc_id
                LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
                LEFT JOIN customer c ON ao.customer_id = c.customer_id
                WHERE t.transaction_id = %s
                """,
                (transaction_id,)
            )
            return self.cursor.fetchone()
        except Exception as e:
            raise e

    # Advanced queries for reports
    def get_monthly_summary_by_account(self, acc_id: str, year: int, month: int) -> Dict[str, Any]:
        """Get monthly transaction summary for an account"""
        try:
            self.cursor.execute(
                """
                SELECT 
                    COUNT(*) as transaction_count,
                    SUM(CASE WHEN type = 'Deposit' THEN amount ELSE 0 END) as total_deposits,
                    SUM(CASE WHEN type = 'Withdrawal' THEN amount ELSE 0 END) as total_withdrawals,
                    SUM(CASE WHEN type = 'banktransfer' THEN amount ELSE 0 END) as total_transfers
                FROM transactions
                WHERE acc_id = %s 
                AND EXTRACT(YEAR FROM created_at) = %s 
                AND EXTRACT(MONTH FROM created_at) = %s
                """,
                (acc_id, year, month)
            )
            result = self.cursor.fetchone()
            
            if result:
                return {
                    'transaction_count': result.get('transaction_count', 0),
                    'total_deposits': float(result.get('total_deposits', 0)),
                    'total_withdrawals': float(result.get('total_withdrawals', 0)),
                    'total_transfers': float(result.get('total_transfers', 0)),
                    'net_change': float(result.get('total_deposits', 0)) - float(result.get('total_withdrawals', 0))
                }
            return {}
        except Exception as e:
            raise e

    def get_top_accounts_by_volume(self, branch_id: str = None, limit: int = 10, start_date: date = None, end_date: date = None) -> List[Dict]:
        """Get top accounts by transaction volume"""
        try:
            base_query = """
                SELECT 
                    t.acc_id,
                    c.full_name as customer_name,
                    COUNT(*) as transaction_count,
                    SUM(t.amount) as total_volume,
                    AVG(t.amount) as avg_amount
                FROM transactions t
                JOIN account a ON t.acc_id = a.acc_id
                LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
                LEFT JOIN customer c ON ao.customer_id = c.customer_id
            """
            
            conditions = []
            params = []
            
            if branch_id:
                conditions.append("a.branch_id = %s")
                params.append(branch_id)
            
            if start_date:
                conditions.append("DATE(t.created_at) >= %s")
                params.append(start_date)
            
            if end_date:
                conditions.append("DATE(t.created_at) <= %s")
                params.append(end_date)
            
            if conditions:
                base_query += " WHERE " + " AND ".join(conditions)
            
            base_query += """
                GROUP BY t.acc_id, c.full_name
                ORDER BY total_volume DESC
                LIMIT %s
            """
            params.append(limit)
            
            self.cursor.execute(base_query, params)
            return self.cursor.fetchall()
        except Exception as e:
            raise e

    # New account-based repository methods
    
    def get_transaction_count_by_account(self, acc_id: str) -> int:
        """Get total transaction count for an account"""
        try:
            self.cursor.execute(
                "SELECT COUNT(*) as count FROM transactions WHERE acc_id = %s",
                (acc_id,)
            )
            result = self.cursor.fetchone()
            return result['count'] if result else 0
        except Exception as e:
            raise e

    def get_account_details_by_account_no(self, account_no: int) -> Optional[Dict[str, Any]]:
        """Get account details including balance by account number"""
        try:
            self.cursor.execute(
                """
                SELECT 
                    a.acc_id,
                    a.account_no,
                    a.balance,
                    c.full_name as account_holder,
                    b.branch_name
                FROM account a
                LEFT JOIN accounts_owner ao ON a.acc_id = ao.acc_id
                LEFT JOIN customer c ON ao.customer_id = c.customer_id
                LEFT JOIN branch b ON a.branch_id = b.branch_id
                WHERE a.account_no = %s
                """,
                (account_no,)
            )
            result = self.cursor.fetchone()
            
            if result:
                return {
                    'acc_id': str(result['acc_id']),
                    'account_no': result['account_no'],
                    'balance': result['balance'],
                    'account_holder': result.get('account_holder'),
                    'branch_name': result.get('branch_name')
                }
            return None
        except Exception as e:
            raise e