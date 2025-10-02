# Fixed Deposit schema - Pydantic models for fixed deposit data validation

from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID
from decimal import Decimal

class FixedDepositResponse(BaseModel):
    fd_id: UUID
    fd_account_no: int
    balance: Decimal
    acc_id: UUID
    opened_date: datetime
    maturity_date: Optional[datetime]
    fd_plan_id: UUID
    created_at: datetime
    updated_at: datetime

    
    # Related data
    account_no: Optional[int] = None
    branch_name: Optional[str] = None
    plan_duration: Optional[int] = None
    plan_interest_rate: Optional[Decimal] = None

    class Config:
        from_attributes = True
