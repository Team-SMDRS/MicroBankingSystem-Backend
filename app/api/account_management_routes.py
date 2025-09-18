from fastapi import APIRouter, Depends, Request
from app.schemas.account_management_schema import CustomerAccountInput
from app.database.db import get_db
from app.repositories.account_management_repo import AccountManagementRepository
from app.repositories.user_repo import UserRepository
from app.services.account_management_service import AccountManagementService

router = APIRouter()

@router.post("/register_customer_with_account")
def register_customer_with_account(
    data: CustomerAccountInput,
    request: Request,
    db=Depends(get_db)
):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    current_user = getattr(request.state, "user", None)
    created_by_user_id = current_user["user_id"] if current_user else None
    # Get branch_id from users_branch table
    branch_id = None
    if created_by_user_id:
        user_repo = UserRepository(db)
        branch_id = user_repo.get_user_branch_id(created_by_user_id)
    return service.register_customer_with_account_minimal(
        input_data=data,
        created_by_user_id=created_by_user_id,
        branch_id=branch_id
    )

@router.get("/accounts/branch/{branch_id}")
def get_accounts_by_branch(branch_id: str, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_accounts_by_branch(branch_id)

@router.get("/account/balance/{account_no}")
def get_account_balance(account_no: str, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_account_balance_by_account_no(account_no)
