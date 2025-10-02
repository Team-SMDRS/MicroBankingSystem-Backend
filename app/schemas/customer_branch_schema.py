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
