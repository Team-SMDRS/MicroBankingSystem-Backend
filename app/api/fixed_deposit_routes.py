# Fixed Deposit routes - API endpoints for fixed deposit operations

from fastapi import APIRouter, Depends
from typing import List

from app.schemas.fixed_deposit_schema import FixedDepositResponse
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



#get fixed deposit by fd_id
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

#get fixed depost by customer id
@router.get("/fixed-deposits/customer/{customer_id}", response_model=List[FixedDepositResponse])
def get_fixed_deposits_by_customer_id(customer_id: str, db=Depends(get_db)):
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposits_by_customer_id(customer_id)



# create new fixed deposit account 
@router.post("/fixed-deposits", response_model=FixedDepositResponse)
def create_fixed_deposit(
    savings_account_no: str,
    amount: float,
    plan_id: str,
    db=Depends(get_db)
):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.create_fixed_deposit(savings_account_no, amount, plan_id)

# get fixed deposit by fd account number
@router.get("/fixed-deposits/account/{fd_account_no}", response_model=FixedDepositResponse)
def get_fixed_deposit_by_account_number(fd_account_no: str, db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fixed_deposit_by_account_number(fd_account_no)

# get fd_plan by fd_id
@router.get("/fixed-deposits/{fd_id}/plan")
def get_fd_plan_by_fd_id(fd_id: str, db=Depends(get_db)):
   
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_fd_plan_by_fd_id(fd_id)

# get all fd plans
@router.get("/fd-plans")
def get_all_fd_plans(db=Depends(get_db)):
   
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_all_fd_plans()

# create new fd plan
@router.post("/fd-plans")
def create_fd_plan(
    duration_months: int,
    interest_rate: float,
    min_amount: float,
    db=Depends(get_db)
):
    
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.create_fd_plan(duration_months, interest_rate, min_amount)

# get saving account by fd account number
@router.get("/fixed-deposits/{fd_account_no}/savings-account")
def get_savings_account_by_fd_number(fd_account_no: str, db=Depends(get_db)):

    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_savings_account_by_fd_number(fd_account_no)

#get owner by fd account number
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
















