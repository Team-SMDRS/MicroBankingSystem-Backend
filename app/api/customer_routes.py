from fastapi import APIRouter, Depends, Request, HTTPException
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


@router.get("/by-nic/{nic}")
def get_customer_by_nic(nic: str, db=Depends(get_db)):
    repo = CustomerRepository(db)
    service = CustomerService(repo)
    return service.get_customer_by_nic(nic)


@router.get("/details/by-nic/{nic}")
def get_customer_details_by_nic(nic: str, db=Depends(get_db)):
    repo = CustomerRepository(db)
    service = CustomerService(repo)
    return service.get_customer_details_by_nic(nic)


@router.get("/customers_details", dependencies=[Depends(customer_auth_dependency)])
async def customers_details(request: Request, db=Depends(get_db)):
    """
    Get complete customer details including:
    - Customer profile
    - All accounts with balances
    - All transactions
    - All fixed deposits
    - Summary statistics
    """
    # Get customer_id from the authenticated token
    customer_id = request.state.customer.get("customer_id")
    
    if not customer_id:
        raise HTTPException(status_code=401, detail="Customer ID not found in token")
    
    repo = CustomerRepository(db)
    service = CustomerService(repo)
    
    return service.get_complete_customer_details(customer_id)

