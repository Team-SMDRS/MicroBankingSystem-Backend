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
