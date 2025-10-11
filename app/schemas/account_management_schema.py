

from pydantic import BaseModel
from typing import Optional



# Input schema: only fields user should provide
class CustomerAccountInput(BaseModel):
    full_name: str
    address: Optional[str] = None
    phone_number: Optional[str] = None
    nic: str
    dob: str
    balance: float
    savings_plan_id: str
    status: Optional[str] = 'active'  # 'active', 'frozen', 'closed'


# Internal use schemas (for service/repo, not direct user input)
class CustomerCreate(BaseModel):
    full_name: str
    address: Optional[str] = None
    phone_number: Optional[str] = None
    nic: str
    dob: str

# Input schema for updating account (savings_plan_id only)
class UpdateAccountInput(BaseModel):
    savings_plan_id: str

# Input schema for updating customer details
class UpdateCustomerInput(BaseModel):
    full_name: Optional[str] = None
    address: Optional[str] = None
    phone_number: Optional[str] = None
    nic: Optional[str] = None

class CustomerLoginCreate(BaseModel):
    username: str
    password: str

class AccountCreate(BaseModel):
  
    branch_id: Optional[str] = None
    savings_plan_id: Optional[str] = None
    balance: float = 0.0
    status: Optional[str] = 'active'  # 'active', 'frozen', 'closed'

class RegisterCustomerWithAccount(BaseModel):
    customer: CustomerCreate
    login: CustomerLoginCreate
    account: AccountCreate

# Input schema for existing customer opening new account
class ExistingCustomerAccountInput(BaseModel):
    nic: str
    balance: float
    savings_plan_id: str

# Input schema for creating a savings plan
class SavingsPlanCreate(BaseModel):
    plan_name: str
    interest_rate: float


# Input schema for closing an account by account number
class CloseAccountInput(BaseModel):
    account_no: int
