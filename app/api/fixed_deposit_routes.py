# Fixed Deposit routes - API endpoints for fixed deposit operations

from fastapi import APIRouter, Depends, Request
from typing import List

from app.schemas.fixed_deposit_schema import FixedDepositPlanResponse, FixedDepositResponse, FDPlanResponse, CreateFDPlanResponse, FixedDepositPlanResponse
from app.database.db import get_db
from app.repositories.fixed_deposit_repo import FixedDepositRepository
from app.services.fixed_deposit_service import FixedDepositService

router = APIRouter()

# get all fixed deposits


@router.get("/fixed-deposits", response_model=List[FixedDepositResponse])
def get_all_fixed_deposits(db=Depends(get_db)):
    """Get all fixed deposit accounts"""
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_all_fixed_deposits()


# get fixed deposit by fd_id
@router.get("/fixed-deposits/fd/{fd_id}", response_model=FixedDepositResponse)
def get_fixed_deposit_by_fd_id(fd_id: str, db=Depends(get_db)):
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposit_by_fd_id(fd_id)

# get fixed deposit by saving account account number


@router.get("/fixed-deposits/savings/{savings_account_no}", response_model=List[FixedDepositResponse])
def get_fixed_deposits_by_savings_account(savings_account_no: str, db=Depends(get_db)):
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposits_by_savings_account(savings_account_no)

# get fixed depost by customer id


@router.get("/fixed-deposits/customer/{customer_id}", response_model=List[FixedDepositResponse])
def get_fixed_deposits_by_customer_id(customer_id: str, db=Depends(get_db)):
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposits_by_customer_id(customer_id)


# create new fixed deposit account
@router.post("/fixed-deposits", response_model=FixedDepositResponse)
async def create_fixed_deposit(request: Request,
                               savings_account_no: str,
                               amount: float,
                               plan_id: str,
                               db=Depends(get_db)
                               ):
    """
    Create a new fixed deposit account.

    Requirements:
    - Customer must have an active savings account
    - Valid and active FD plan

    Args:
        savings_account_no: The savings account number to link with FD
        amount: Amount to deposit in the FD
        plan_id: ID of the FD plan to use

    Returns:
        Fixed deposit details with related information
    """
    current_user = getattr(request.state, "user", None)
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.create_fixed_deposit(savings_account_no, amount, plan_id, created_by_user_id=current_user["user_id"])

# get fixed deposit by fd account number


@router.get("/fixed-deposits/account/{fd_account_no}", response_model=FixedDepositResponse)
def get_fixed_deposit_by_account_number(fd_account_no: str, db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposit_by_account_number(fd_account_no)

# get fd_plan by fd_id


@router.get("/fixed-deposits/{fd_id}/plan", response_model=FixedDepositPlanResponse)
def get_fd_plan_by_fd_id(fd_id: str, db=Depends(get_db)):
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fd_plan_by_fd_id(fd_id)

# get all fd plans


@router.get("/fd-plans", response_model=List[FDPlanResponse])
def get_all_fd_plans(db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_all_fd_plans()

# create new fd plan


@router.post("/fd-plans", response_model=CreateFDPlanResponse)
async def create_fd_plan(
    request: Request,
    duration_months: int,
    interest_rate: float,
    db=Depends(get_db)
):
    """
    Create a new fixed deposit plan.

    Args:
        duration_months: Duration of the FD plan in months
        interest_rate: Annual interest rate (percentage)

    Returns:
        Success message with created FD plan details
    """
    current_user = getattr(request.state, "user", None)
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.create_fd_plan(duration_months, interest_rate, created_by_user_id=current_user["user_id"])

# update fd plan status


@router.put("/fd-plans/{fd_plan_id}/status", response_model=FDPlanResponse)
async def update_fd_plan_status(
    request: Request,
    fd_plan_id: str,
    status: str,
    db=Depends(get_db)
):
    """
    Update the status of an FD plan.

    Args:
        fd_plan_id: ID of the FD plan to update
        status: New status for the FD plan (e.g., 'active', 'inactive')

    Returns:
        Updated FD plan details
    """
    current_user = getattr(request.state, "user", None)
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.update_fd_plan_status(fd_plan_id, status, updated_by_user_id=current_user["user_id"])

# get saving account by fd account number


@router.get("/fixed-deposits/{fd_account_no}/savings-account")
def get_savings_account_by_fd_number(fd_account_no: str, db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_savings_account_by_fd_number(fd_account_no)

# get owner by fd account number


@router.get("/fixed-deposits/{fd_account_no}/owner")
def get_owner_by_fd_number(fd_account_no: str, db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_owner_by_fd_number(fd_account_no)

# get branch by fd account number


@router.get("/fixed-deposits/{fd_account_no}/branch")
def get_branch_by_fd_number(fd_account_no: str, db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_branch_by_fd_number(fd_account_no)

# get all fixed deposits of a branch id


@router.get("/branches/{branch_id}/fixed-deposits", response_model=List[FixedDepositResponse])
def get_fixed_deposits_by_branch(branch_id: str, db=Depends(get_db)):
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposits_by_branch(branch_id)

# get fd plan by plan id
# @router.get("/fd-plans/{fd_plan_id}", response_model=FDPlanResponse)
# def get_fd_plan_by_id(fd_plan_id: str, db=Depends(get_db)):
#     """Get FD plan details by plan ID"""
#     repo = FixedDepositRepository(db)
#     service = FixedDepositService(repo)
#     return service.get_fd_plan_by_fd_id(fd_plan_id)


# get all active fd plans
@router.get("/active-fd-plans", response_model=List[FDPlanResponse])
def get_active_fd_plans(db=Depends(get_db)):
    """Get all active FD plans only"""
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_active_fd_plans()

# get fixed deposits by status


@router.get("/fixed-deposits/status/{status}", response_model=List[FixedDepositResponse])
def get_fixed_deposits_by_status(status: str, db=Depends(get_db)):
    """Get all fixed deposits by status (active, matured, etc.)"""
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposits_by_status(status)

# get matured fixed deposits


@router.get("/fixed-deposits/matured", response_model=List[FixedDepositResponse])
def get_matured_fixed_deposits(db=Depends(get_db)):
    """Get all matured fixed deposits"""
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_matured_fixed_deposits()

# get fixed deposits by plan id


@router.get("/fd-plans/{fd_plan_id}/fixed-deposits", response_model=List[FixedDepositResponse])
def get_fixed_deposits_by_plan_id(fd_plan_id: str, db=Depends(get_db)):
    """Get all fixed deposit accounts for a given FD plan ID"""
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposits_by_plan_id(fd_plan_id)


# close fixed deposit (mark as closed, balace set to zero and withdraw balance to linked savings account) before maturity or after maturity
@router.post("/fixed-deposits/{fd_id}/close")
def close_fixed_deposit(fd_id: str, request: Request, db=Depends(get_db)):
    """Close a fixed deposit account before or after maturity"""
    current_user = getattr(request.state, "user", None)
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.close_fixed_deposit(fd_id, closed_by_user_id=current_user["user_id"])
