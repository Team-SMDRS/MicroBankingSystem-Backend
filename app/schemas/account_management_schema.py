
from pydantic import BaseModel
from typing import Optional


# Input schema: only fields user should provide
class CustomerAccountInput(BaseModel):
    full_name: str
    address: Optional[str] = None
    phone_number: Optional[str] = None
    nic: str
    balance: float
    savings_plan_id: str


# Internal use schemas (for service/repo, not direct user input)
class CustomerCreate(BaseModel):
    full_name: str
    address: Optional[str] = None
    phone_number: Optional[str] = None
    nic: str

class CustomerLoginCreate(BaseModel):
    username: str
    password: str

class AccountCreate(BaseModel):
    account_no: str
    branch_id: Optional[str] = None
    savings_plan_id: Optional[str] = None
    balance: float = 0.0

class RegisterCustomerWithAccount(BaseModel):
    customer: CustomerCreate
    login: CustomerLoginCreate
    account: AccountCreate
