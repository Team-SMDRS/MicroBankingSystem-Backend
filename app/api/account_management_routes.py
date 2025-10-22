# Route to get customer details by customer_id






from fastapi import APIRouter, Depends, Request
from app.middleware.require_permission import require_permission
from app.schemas.account_management_schema import CustomerAccountInput, ExistingCustomerAccountInput, UpdateAccountInput, UpdateCustomerInput
from app.schemas.account_management_schema import CloseAccountInput
from app.database.db import get_db
from app.repositories.account_management_repo import AccountManagementRepository
from app.repositories.user_repo import UserRepository
from app.services.account_management_service import AccountManagementService
# from app.docs.import roles.md


router = APIRouter()


@router.get("/customer/{customer_id}")
@require_permission("customer-view")
async def get_customer_by_id(customer_id: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    result = service.get_customer_by_id(customer_id)
    if not result:
        return {"detail": "Customer not found"}
    return result


# Route for existing customer to open a new account using NIC
@router.post("/existing_customer/open_account")
@require_permission("account-open")
async def open_account_for_existing_customer(
    data: ExistingCustomerAccountInput,
    request: Request,
    db=Depends(get_db)
):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    current_user = getattr(request.state, "user", None)
    created_by_user_id = current_user["user_id"] if current_user else None
    branch_id = None
    if created_by_user_id:
        user_repo = UserRepository(db)
        branch_id = user_repo.get_user_branch_id(created_by_user_id)
    return service.open_account_for_existing_customer(data, created_by_user_id, branch_id)

#@router.get("/my_profile")
#@require_permission("admin")
#async def my_profile(request: Request):
    # Example: return some user info from JWT
    #return {"message": "My Profile", "user": getattr(request.state, "user", {})}

#@router.get("/accounts")
#@require_permission("account:view")
#async def get_accounts(request: Request):
    #return {"msg": "You can view accounts!", "permissions": request.state.user.get("permissions", [])}

@router.post("/register_customer_with_account")
@require_permission("account-open")
async def register_customer_with_account(
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
@require_permission("account-view")
async def get_accounts_by_branch(branch_id: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_accounts_by_branch(branch_id)

@router.get("/account/balance/{account_no}")
@require_permission("account-view")
async def get_account_balance(account_no: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_account_balance_by_account_no(account_no)

@router.get("/account/{account_no}/owner")
@require_permission("account-view")
async def get_account_owner(account_no: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    owners = repo.get_account_owner(account_no)
    if not owners:
        return {"detail": "Owner not found"}
    return owners

# Route to get all accounts for a given NIC number
@router.get("/accounts/by-nic/{nic}")
@require_permission("account-view")
async def get_accounts_by_nic(nic: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    accounts = repo.get_accounts_by_nic(nic)
    return accounts


# Route to close an account (soft delete) by account number
@router.post("/account/close")
@require_permission("account-close")
async def close_account(input_data: CloseAccountInput, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    current_user = getattr(request.state, "user", None)
    closed_by_user_id = current_user["user_id"] if current_user else None
    return service.close_account_by_account_no(input_data.account_no, closed_by_user_id)


# Route to update customer details
@router.put("/customer/{customer_id}")
@require_permission("customer-update")
async def update_customer(customer_id: str, update_data: UpdateCustomerInput, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    updated = repo.update_customer(customer_id, update_data.dict(exclude_unset=True))
    if updated is None:
        return {"detail": "No valid fields to update."}
    return updated if updated else {"detail": "Customer not found or not updated."}

@router.get("/accounts/all")
@require_permission("account-view")
async def get_all_accounts(request: Request,db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    accounts = repo.get_all_accounts()
    return accounts

@router.get("/account/details/{account_no}")
@require_permission("account-view") 
async def get_account_details(account_no: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_account_details_by_account_no(account_no)

@router.get("/accounts/branch/{branch_id}/count")
@require_permission("report-view")
async def get_account_count_by_branch(branch_id: str, request: Request, db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_account_count_by_branch(branch_id)

@router.get("/accounts/count")
@require_permission("report-view")
async def get_total_account_count(request: Request,db=Depends(get_db)):
    repo = AccountManagementRepository(db)
    service = AccountManagementService(repo)
    return service.get_total_account_count()

