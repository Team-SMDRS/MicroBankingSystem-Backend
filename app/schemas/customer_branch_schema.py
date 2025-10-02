from pydantic import BaseModel
from typing import Optional
from app.repositories.user_repo import UserRepository


class CustomerNameID(BaseModel):
    customer_id: str
    name: str
    nic: str


class CustomerCount(BaseModel):
    count: int


class CustomerCountByBranch(BaseModel):
    branch_id: str
    count: int


class CustomerCountByBranchID(BaseModel):
    branch_id: str
    count: int


class CustomersByBranchID(BaseModel):
    customer_id: str
    name: str
    nic: str

# get count of all accounts in branch id


class AccountsCountByBranchID(BaseModel):
    branch_id: str
    count: int

# get total balance of all accounts in branch id


class TotalBalanceByBranchID(BaseModel):
    branch_id: str
    total_balance: Optional[float] = 0.0
