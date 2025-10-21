"""Overview routes - API endpoints for reports and summaries"""

from fastapi import APIRouter, Depends, Query, HTTPException
from app.database.db import get_db
from app.repositories.overview_repo import OverviewRepository
from app.repositories.customer_repo import CustomerRepository
from app.services.overview_services import OverviewService
from app.services.customer_service import CustomerService
from app.schemas.overview_schema import (
    MonthlyInterestByAccountTypeResponse,
    MonthlyInterestBySavingsPlanResponse,
    MonthlyInterestByFDPlanResponse,
    MonthlyTransactionSummaryResponse,
    BranchWiseInterestDistributionResponse
)

router = APIRouter()


@router.get(
    "/monthly_interest_distribution_summary",
    response_model=MonthlyInterestByAccountTypeResponse
)
def get_monthly_interest_distribution_summary(
    month: int = Query(None, ge=1, le=12, description="Month number (1-12)"),
    year: int = Query(None, ge=2020, description="Year"),
    db=Depends(get_db)
):
    """
    Get monthly interest distribution summary by account type (Savings/Fixed Deposit).
    
    - **month**: Optional month (1-12). Defaults to current month.
    - **year**: Optional year. Defaults to current year.
    
    Returns interest totals and average for each account type.
    """
    repo = OverviewRepository(db)
    service = OverviewService(repo)
    return service.get_monthly_interest_distribution_by_account_type(month=month, year=year)


@router.get(
    "/monthly_interest_by_savings_plan",
    response_model=MonthlyInterestBySavingsPlanResponse
)
def get_monthly_interest_by_savings_plan(
    month: int = Query(None, ge=1, le=12, description="Month number (1-12)"),
    year: int = Query(None, ge=2020, description="Year"),
    db=Depends(get_db)
):
    """
    Get monthly interest distribution by savings plan.
    
    - **month**: Optional month (1-12). Defaults to current month.
    - **year**: Optional year. Defaults to current year.
    
    Returns interest statistics for each savings plan.
    """
    repo = OverviewRepository(db)
    service = OverviewService(repo)
    return service.get_monthly_interest_by_savings_plan(month=month, year=year)


@router.get(
    "/monthly_interest_by_fd_plan",
    response_model=MonthlyInterestByFDPlanResponse
)
def get_monthly_interest_by_fd_plan(
    month: int = Query(None, ge=1, le=12, description="Month number (1-12)"),
    year: int = Query(None, ge=2020, description="Year"),
    db=Depends(get_db)
):
    """
    Get monthly interest distribution by fixed deposit plan.
    
    - **month**: Optional month (1-12). Defaults to current month.
    - **year**: Optional year. Defaults to current year.
    
    Returns interest statistics for each FD plan.
    """
    repo = OverviewRepository(db)
    service = OverviewService(repo)
    return service.get_monthly_interest_by_fd_plan(month=month, year=year)


@router.get(
    "/monthly_transaction_summary",
    response_model=MonthlyTransactionSummaryResponse
)
def get_monthly_transaction_summary(
    month: int = Query(None, ge=1, le=12, description="Month number (1-12)"),
    year: int = Query(None, ge=2020, description="Year"),
    db=Depends(get_db)
):
    """
    Get monthly transaction summary by transaction type.
    
    - **month**: Optional month (1-12). Defaults to current month.
    - **year**: Optional year. Defaults to current year.
    
    Returns transaction count and amount statistics for each type.
    """
    repo = OverviewRepository(db)
    service = OverviewService(repo)
    return service.get_monthly_transaction_summary(month=month, year=year)


@router.get(
    "/branch_wise_interest_distribution",
    response_model=BranchWiseInterestDistributionResponse
)
def get_branch_wise_interest_distribution(
    month: int = Query(None, ge=1, le=12, description="Month number (1-12)"),
    year: int = Query(None, ge=2020, description="Year"),
    db=Depends(get_db)
):
    """
    Get monthly interest distribution by branch.
    
    - **month**: Optional month (1-12). Defaults to current month.
    - **year**: Optional year. Defaults to current year.
    
    Returns interest statistics for each branch.
    """
    repo = OverviewRepository(db)
    service = OverviewService(repo)
    return service.get_branch_wise_interest_distribution(month=month, year=year)


@router.get("/customer/details-by-nic/{nic}")
def get_customer_details_by_nic(
    nic: str,
    db=Depends(get_db)
):
    """
    Get customer details by NIC number.
    
    - **nic**: National Identity Card number
    
    Returns customer profile information including:
    - Customer ID
    - Full Name
    - NIC
    - Address
    - Phone Number
    - Date of Birth
    - Created by user name
    """
    repo = CustomerRepository(db)
    service = CustomerService(repo)
    
    customer = service.get_customer_details_by_nic(nic)
    if not customer:
        raise HTTPException(status_code=404, detail=f"Customer with NIC {nic} not found")
    
    return customer


@router.get("/customer/complete-details/{customer_id}")
def get_complete_customer_details(
    customer_id: str,
    db=Depends(get_db)
):
    """
    Get complete customer details by customer ID.
    
    - **customer_id**: Unique customer identifier
    
    Returns comprehensive customer information including:
    - Customer profile (name, NIC, address, etc.)
    - All savings accounts with balances
    - All transactions
    - All fixed deposits
    - Summary statistics (total balance, active accounts, etc.)
    """
    repo = CustomerRepository(db)
    service = CustomerService(repo)
    
    return service.get_complete_customer_details(customer_id)

