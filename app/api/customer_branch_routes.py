from app.repositories.customer_branch_repo import CustomerBranchRepository
from fastapi import APIRouter, Depends, Request
from app.middleware.require_permission import require_permission
from app.repositories.user_repo import UserRepository
from app.services.customer_branch_service import CustomerBranchService
from app.database.db import get_db

router = APIRouter()

# get all customers


@router.get("/customers")
@require_permission("admin")
def get_all_customers(request: Request, db=Depends(get_db)):

    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.get_all_customers()


# get all customers of users branch
@router.get("/customers/users_branch")
@require_permission("agent")
def get_customers_by_branch(request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    user_repo = UserRepository(db)
    current_user = getattr(request.state, "user", None)
    branch_id = user_repo.get_user_branch_id(current_user["user_id"])
    service = CustomerBranchService(repo)
    return service.get_customers_by_branch(branch_id)


# get all customers count
@router.get("/customers/count")
@require_permission("admin")
def get_customers_count(request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.get_customers_count()


# get count of all customers in the current user's branch

@router.get("/customers/users_branch/count")
@require_permission("agent")
def get_customers_count_by_branch(request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    user_repo = UserRepository(db)
    service = CustomerBranchService(repo)
    current_user = getattr(request.state, "user", None)
    branch_id = user_repo.get_user_branch_id(current_user["user_id"])
    return service.get_customers_count_by_branch(branch_id)

# get count of all users in branch_id


# @router.get("/customers/branch/{branch_id}/count")
# def get_customers_count_by_branch_id(branch_id: str, db=Depends(get_db)):
#     repo = CustomerBranchRepository(db)
#     service = CustomerBranchService(repo)
#     return service.get_customers_count_by_branch(branch_id)


# get all customers by branch id
@router.get("/customers/branch/{branch_id}")
@require_permission("admin")
def get_customers_by_branch_id(branch_id: str, request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.get_customers_by_branch_id(branch_id)

# get count of all accounts in branch id


@router.get("/accounts/branch/{branch_id}/count")
@require_permission("manager")
def get_accounts_count_by_branch_id(branch_id: str, request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.get_accounts_count_by_branch_id(branch_id)

# get total balance of all accounts in branch id


@router.get("/accounts/branch/{branch_id}/total_balance")
@require_permission("manager")
def get_total_balance_by_branch_id(branch_id: str, request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.get_total_balance_by_branch_id(branch_id)

# search customers by name
@router.get("/customers/search")
@require_permission("agent")
def search_customers(name: str, request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.search_customers_by_name(name)
