# Fixed Deposit schema - Pydantic models for fixed deposit data validation

from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID
from decimal import Decimal

class CreateFixedDepositRequest(BaseModel):
    savings_account_no: str
    amount: float
    plan_id: str

    class Config:
        from_attributes = True

class FixedDepositResponse(BaseModel):
    fd_id: UUID
    fd_account_no: int
    balance: Decimal
    acc_id: UUID
    opened_date: datetime
    maturity_date: datetime
    fd_plan_id: UUID
    fd_created_at: datetime   # match SQL alias
    fd_updated_at: datetime   # match SQL alias
    account_no: int
    branch_name: str
    plan_duration: int
    plan_interest_rate: Decimal


    class Config:
        from_attributes = True

class FDPlanResponse(BaseModel):
    fd_plan_id: UUID
    duration: int
    interest_rate: Decimal
    status: str
    created_at: datetime
    updated_at: datetime
    created_by: Optional[UUID] = None
    updated_by: Optional[UUID] = None

    class Config:
        from_attributes = True

class CreateFDPlanResponse(BaseModel):
    message: str
    fd_plan: FDPlanResponse

    class Config:
        from_attributes = True



class FixedDepositDBResponse(BaseModel):
    fd_id: UUID
    fd_account_no: int
    balance: Decimal
    acc_id: UUID
    opened_date: datetime
    maturity_date: datetime
    fd_plan_id: UUID
    created_at: datetime      # DB key
    updated_at: datetime      # DB key
    account_no: int
    branch_name: str
    plan_duration: int
    plan_interest_rate: Decimal



class FixedDepositPlanResponse(BaseModel):
    fd_plan_id: UUID
    duration: int
    interest_rate: Decimal
    status: str
    created_at: datetime
    updated_at: datetime