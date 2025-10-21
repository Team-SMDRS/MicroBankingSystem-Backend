"""Overview schemas for API responses"""

from pydantic import BaseModel
from typing import List, Optional


class AccountTypeInterestSummary(BaseModel):
    """Summary of interest distribution by account type"""
    account_type: str
    total_accounts: int
    total_interest: float
    average_interest: float


class MonthlyInterestByAccountTypeResponse(BaseModel):
    """Response for monthly interest distribution by account type"""
    month: int
    year: int
    month_name: str
    account_types: List[AccountTypeInterestSummary]
    grand_total_accounts: int
    grand_total_interest: float
    average_interest_all: float


class SavingsPlanInterestSummary(BaseModel):
    """Summary of interest distribution by savings plan"""
    plan_name: str
    interest_rate: float
    total_accounts: int
    total_interest: float
    average_interest: float
    max_interest: float
    min_interest: float


class MonthlyInterestBySavingsPlanResponse(BaseModel):
    """Response for monthly interest distribution by savings plan"""
    month: int
    year: int
    month_name: str
    savings_plans: List[SavingsPlanInterestSummary]
    grand_total_accounts: int
    grand_total_interest: float


class FDPlanInterestSummary(BaseModel):
    """Summary of interest distribution by FD plan"""
    plan_duration: str
    interest_rate: float
    total_accounts: int
    total_interest: float
    average_interest: float
    max_interest: float
    min_interest: float


class MonthlyInterestByFDPlanResponse(BaseModel):
    """Response for monthly interest distribution by FD plan"""
    month: int
    year: int
    month_name: str
    fd_plans: List[FDPlanInterestSummary]
    grand_total_accounts: int
    grand_total_interest: float


class TransactionTypeSummary(BaseModel):
    """Summary of transactions by type"""
    type: str
    transaction_count: int
    total_amount: float
    average_amount: float
    max_amount: float
    min_amount: float


class MonthlyTransactionSummaryResponse(BaseModel):
    """Response for monthly transaction summary"""
    month: int
    year: int
    month_name: str
    transactions: List[TransactionTypeSummary]
    grand_total_transactions: int
    grand_total_amount: float


class BranchInterestSummary(BaseModel):
    """Summary of interest distribution by branch"""
    branch_name: str
    address: str
    total_accounts: int
    total_interest: float
    average_interest: float
    max_interest: float
    min_interest: float


class BranchWiseInterestDistributionResponse(BaseModel):
    """Response for branch-wise interest distribution"""
    month: int
    year: int
    month_name: str
    branches: List[BranchInterestSummary]
    grand_total_accounts: int
    grand_total_interest: float
