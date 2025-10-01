from app.repositories.customer_branch_repo import CustomerBranchRepository
from fastapi import APIRouter, Depends, Request
from app.middleware.require_permission import require_permission
from app.repositories.user_repo import UserRepository
from app.services.customer_branch_service import CustomerBranchService
from app.database.db import get_db

router = APIRouter()

# get all customers 
@router.get("/customers")
def get_all_customers ( db=Depends(get_db)):
    
    repo = CustomerBranchRepository(db)
    service = CustomerBranchService(repo)
    return service.get_all_customers()


#get all customers of users branch
@router.get("/customers/users_branch")
def get_customers_by_branch(request: Request, db=Depends(get_db)):
    repo = CustomerBranchRepository(db)
    user_repo = UserRepository(db)
    current_user = getattr(request.state, "user", None)
    branch_id = user_repo.get_user_branch_id(current_user["user_id"])
    service = CustomerBranchService(repo)
    return service.get_customers_by_branch(branch_id)