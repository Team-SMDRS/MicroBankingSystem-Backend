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
    updated_at: Optional[datetime] = None
    created_by: Optional[str] = None
    updated_by: Optional[str] = None

    class Config:
        from_attributes = True


class BranchSummary(BaseModel):
    branch_id: UUID
    name: Optional[str]
    address: Optional[str]
    created_at: datetime

    class Config:
        from_attributes = True

# get branch by id


# get branch by name ()
# update branch details (name, address) by branch id PUT /branches/{branch_id}
class UpdateBranch(BaseModel):
    name: Optional[str]
    address: Optional[str]


# create new branch
class CreateBranch(BaseModel):
    name: str
    address: str
