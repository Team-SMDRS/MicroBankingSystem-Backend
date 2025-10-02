# Branch routes - API endpoints for branch operations

from fastapi import APIRouter, Depends
from typing import List

from app.schemas.branch_schema import BranchResponse
from app.database.db import get_db
from app.repositories.branch_repo import BranchRepository
from app.services.branch_service import BranchService

router = APIRouter()

@router.get("/branches", response_model=dict)
def get_all_branches(db=Depends(get_db)):
    """Get all branches"""
    repo = BranchRepository(db)
    service = BranchService(repo)
    return service.get_all_branches()