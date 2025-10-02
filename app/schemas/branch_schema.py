# Branch schema - Pydantic models for branch data validation

from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID

class BranchResponse(BaseModel):
    branch_id: UUID
    name: Optional[str]
    address: Optional[str]
    created_at: datetime

    class Config:
        from_attributes = True