from fastapi import APIRouter, Depends, Request
from app.middleware.customer_middleware import customer_auth_dependency


from app.schemas.customer_schema import LoginCustomer
from app.database.db import get_db
from app.repositories.customer_repo import CustomerRepository
from app.services.customer_service import CustomerService


router = APIRouter()

# Public route (no middleware)

@router.post("/login")
def login_customer(user: LoginCustomer, db=Depends(get_db)):
    repo = CustomerRepository(db)
  
    service = CustomerService(repo)
    return service.login_customer(user)



# @router.post("/login")
# async def login_customer():
#     return {"message": "Login endpoint - no auth required"}

# Protected route (uses middleware)
@router.get("/my_profile", dependencies=[Depends(customer_auth_dependency)])
async def my_profile(request: Request):
    return {
        "message": "My Profile",
        "customer": getattr(request.state, "customer", {})
    }