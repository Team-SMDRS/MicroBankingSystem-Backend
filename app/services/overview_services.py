"""Overview service - Business logic for overview and reports"""

from app.repositories.overview_repo import OverviewRepository
from datetime import datetime
from decimal import Decimal


class OverviewService:
    def __init__(self, repo: OverviewRepository):
        self.repo = repo

    def get_monthly_interest_distribution_by_account_type(self, month: int = None, year: int = None):
        """
        Get monthly interest distribution summary by account type.
        
        Args:
            month: Month number (1-12). If None, uses current month.
            year: Year (e.g., 2025). If None, uses current year.
        
        Returns:
            Dict with account_type summaries and totals
        """
        # Validate month
        if month is None:
            month = datetime.now().month
        if year is None:
            year = datetime.now().year

        if not (1 <= month <= 12):
            raise ValueError("Month must be between 1 and 12")
        if year < 2020 or year > datetime.now().year + 1:
            raise ValueError("Invalid year provided")

        result = self.repo.get_monthly_interest_distribution_by_account_type(year, month)

        # Format response
        summary = {
            "month": month,
            "year": year,
            "month_name": datetime(year, month, 1).strftime("%B"),
            "account_types": []
        }

        total_accounts = 0
        total_interest = Decimal('0.00')

        for row in result:
            if row:
                summary["account_types"].append({
                    "account_type": row['account_type'],
                    "total_accounts": row['total_accounts'] or 0,
                    "total_interest": float(row['total_interest'] or 0),
                    "average_interest": float(row['average_interest'] or 0)
                })
                total_accounts += row['total_accounts'] or 0
                total_interest += row['total_interest'] or Decimal('0.00')

        summary["grand_total_accounts"] = total_accounts
        summary["grand_total_interest"] = float(total_interest)
        summary["average_interest_all"] = float(total_interest / total_accounts) if total_accounts > 0 else 0

        return summary

    def get_monthly_interest_by_savings_plan(self, month: int = None, year: int = None):
        """
        Get monthly interest distribution by savings plan.
        
        Args:
            month: Month number (1-12)
            year: Year (e.g., 2025)
        
        Returns:
            Dict with savings plan summaries
        """
        if month is None:
            month = datetime.now().month
        if year is None:
            year = datetime.now().year

        if not (1 <= month <= 12):
            raise ValueError("Month must be between 1 and 12")

        result = self.repo.get_monthly_interest_by_savings_plan(year, month)

        summary = {
            "month": month,
            "year": year,
            "month_name": datetime(year, month, 1).strftime("%B"),
            "savings_plans": []
        }

        total_accounts = 0
        total_interest = Decimal('0.00')

        for row in result:
            if row:
                summary["savings_plans"].append({
                    "plan_name": row['plan_name'],
                    "interest_rate": float(row['interest_rate'] or 0),
                    "total_accounts": row['total_accounts'] or 0,
                    "total_interest": float(row['total_interest'] or 0),
                    "average_interest": float(row['average_interest'] or 0),
                    "max_interest": float(row['max_interest'] or 0),
                    "min_interest": float(row['min_interest'] or 0)
                })
                total_accounts += row['total_accounts'] or 0
                total_interest += row['total_interest'] or Decimal('0.00')

        summary["grand_total_accounts"] = total_accounts
        summary["grand_total_interest"] = float(total_interest)

        return summary

    def get_monthly_interest_by_fd_plan(self, month: int = None, year: int = None):
        """
        Get monthly interest distribution by fixed deposit plan.
        
        Args:
            month: Month number (1-12)
            year: Year (e.g., 2025)
        
        Returns:
            Dict with FD plan summaries
        """
        if month is None:
            month = datetime.now().month
        if year is None:
            year = datetime.now().year

        if not (1 <= month <= 12):
            raise ValueError("Month must be between 1 and 12")

        result = self.repo.get_monthly_interest_by_fd_plan(year, month)

        summary = {
            "month": month,
            "year": year,
            "month_name": datetime(year, month, 1).strftime("%B"),
            "fd_plans": []
        }

        total_accounts = 0
        total_interest = Decimal('0.00')

        for row in result:
            if row:
                summary["fd_plans"].append({
                    "plan_duration": row['plan_duration'],
                    "interest_rate": float(row['interest_rate'] or 0),
                    "total_accounts": row['total_accounts'] or 0,
                    "total_interest": float(row['total_interest'] or 0),
                    "average_interest": float(row['average_interest'] or 0),
                    "max_interest": float(row['max_interest'] or 0),
                    "min_interest": float(row['min_interest'] or 0)
                })
                total_accounts += row['total_accounts'] or 0
                total_interest += row['total_interest'] or Decimal('0.00')

        summary["grand_total_accounts"] = total_accounts
        summary["grand_total_interest"] = float(total_interest)

        return summary

    def get_monthly_transaction_summary(self, month: int = None, year: int = None):
        """
        Get monthly transaction summary by type.
        
        Args:
            month: Month number (1-12)
            year: Year (e.g., 2025)
        
        Returns:
            Dict with transaction type summaries
        """
        if month is None:
            month = datetime.now().month
        if year is None:
            year = datetime.now().year

        if not (1 <= month <= 12):
            raise ValueError("Month must be between 1 and 12")

        result = self.repo.get_monthly_transaction_summary(year, month)

        summary = {
            "month": month,
            "year": year,
            "month_name": datetime(year, month, 1).strftime("%B"),
            "transactions": []
        }

        grand_total_transactions = 0
        grand_total_amount = Decimal('0.00')

        for row in result:
            if row:
                summary["transactions"].append({
                    "type": row['type'],
                    "transaction_count": row['transaction_count'] or 0,
                    "total_amount": float(row['total_amount'] or 0),
                    "average_amount": float(row['average_amount'] or 0),
                    "max_amount": float(row['max_amount'] or 0),
                    "min_amount": float(row['min_amount'] or 0)
                })
                grand_total_transactions += row['transaction_count'] or 0
                grand_total_amount += row['total_amount'] or Decimal('0.00')

        summary["grand_total_transactions"] = grand_total_transactions
        summary["grand_total_amount"] = float(grand_total_amount)

        return summary

    def get_branch_wise_interest_distribution(self, month: int = None, year: int = None):
        """
        Get monthly interest distribution by branch.
        
        Args:
            month: Month number (1-12)
            year: Year (e.g., 2025)
        
        Returns:
            Dict with branch-wise summaries
        """
        if month is None:
            month = datetime.now().month
        if year is None:
            year = datetime.now().year

        if not (1 <= month <= 12):
            raise ValueError("Month must be between 1 and 12")

        result = self.repo.get_branch_wise_interest_distribution(year, month)

        summary = {
            "month": month,
            "year": year,
            "month_name": datetime(year, month, 1).strftime("%B"),
            "branches": []
        }

        total_accounts = 0
        total_interest = Decimal('0.00')

        for row in result:
            if row:
                summary["branches"].append({
                    "branch_name": row['branch_name'],
                    "address": row['address'],
                    "total_accounts": row['total_accounts'] or 0,
                    "total_interest": float(row['total_interest'] or 0),
                    "average_interest": float(row['average_interest'] or 0),
                    "max_interest": float(row['max_interest'] or 0),
                    "min_interest": float(row['min_interest'] or 0)
                })
                total_accounts += row['total_accounts'] or 0
                total_interest += row['total_interest'] or Decimal('0.00')

        summary["grand_total_accounts"] = total_accounts
        summary["grand_total_interest"] = float(total_interest)

        return summary
    
    def get_branch_overview(self, branch_id: str):
        """Get comprehensive branch overview with chart data."""
        
        result = self.repo.get_branch_overview(branch_id)
        if not result:
            raise ValueError(f"Branch {branch_id} not found")

        return {
            "branch": {
                "id": str(result['branch']['branch_id']),
                "name": result['branch']['name'],
                "address": result['branch']['address']
            },
            "account_statistics": {
                "total_accounts": result['account_stats']['total_accounts'] or 0,
                "active_accounts": result['account_stats']['active_accounts'] or 0,
                "total_balance": float(result['account_stats']['total_balance'] or 0),
                "average_balance": float(result['account_stats']['average_balance'] or 0)
            },
            "accounts_by_plan": [
                {
                    "plan_name": row['plan_name'] or "Unassigned",
                    "count": row['account_count'],
                    "total_balance": float(row['total_balance'] or 0)
                }
                for row in result['accounts_by_plan']
            ],
            "daily_transactions": [
                {
                    "date": row['transaction_date'].isoformat() if row['transaction_date'] else None,
                    "count": row['transaction_count'],
                    "amount": float(row['total_amount'] or 0)
                }
                for row in result['daily_transactions']
            ],
            "transaction_types": [
                {
                    "type": row['type'],
                    "count": row['transaction_count'],
                    "total_amount": float(row['total_amount'] or 0)
                }
                for row in result['transaction_types']
            ],
            "account_status": [
                {
                    "status": row['status'],
                    "count": row['count'],
                    "total_balance": float(row['total_balance'] or 0)
                }
                for row in result['account_status']
            ],
            "top_accounts": [
                {
                    "account_no": str(row['account_no']),
                    "balance": float(row['balance'] or 0),
                    "status": row['status'],
                    "plan": row['plan_name']
                }
                for row in result['top_accounts']
            ],
            "monthly_trend": [
                {
                    "year": int(row['year']),
                    "month": int(row['month']),
                    "transaction_count": row['transaction_count'],
                    "total_amount": float(row['total_amount'] or 0)
                }
                for row in result['monthly_trend']
            ],
            "weekly_interest": [
                {
                    "week_start": row['week_start'].isoformat() if row['week_start'] else None,
                    "total_interest": float(row['total_interest'] or 0),
                    "count": row['interest_count']
                }
                for row in result['weekly_interest']
            ]
        }

    def get_branch_comparison(self):
        """Get comparative data for all branches."""
        results = self.repo.get_branch_comparison()
        
        return {
            "branches": [
                {
                    "branch_id": str(row['branch_id']),
                    "branch_name": row['branch_name'],
                    "total_accounts": row['total_accounts'] or 0,
                    "active_accounts": row['active_accounts'] or 0,
                    "total_balance": float(row['total_balance'] or 0),
                    "total_transactions": row['total_transactions'] or 0,
                    "total_interest": float(row['total_interest'] or 0)
                }
                for row in results
            ],
            "total_all_branches": sum(float(row['total_balance'] or 0) for row in results)
        }
