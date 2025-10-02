# Branch routes - API endpoints for branch operations

from fastapi import APIRouter, Depends
from typing import List

from app.schemas.branch_schema import BranchResponse
from app.database.db import get_db
from app.repositories.branch_repo import BranchRepository
from app.services.branch_service import BranchService

router = APIRouter()
# get all branches


@router.get("/branches", response_model=List[BranchResponse])
def get_all_branches(db=Depends(get_db)):
    """Get all branches"""
    repo = BranchRepository(db)
    service = BranchService(repo)
    return service.get_all_branches()


# get branch by id as a list
@router.get("/branches/{branch_id}", response_model=List[BranchResponse])
def get_branch_by_id(branch_id: str, db=Depends(get_db)):
    """Get branch by ID"""
    repo = BranchRepository(db)
    service = BranchService(repo)
    return service.get_branch_by_id(branch_id)

# get branch by name


@router.get("/branches/name/{branch_name}", response_model=List[BranchResponse])
def get_branch_by_name(branch_name: str, db=Depends(get_db)):
    """Get branch by name"""
    repo = BranchRepository(db)
    service = BranchService(repo)
    return service.get_branch_by_name(branch_name)


# update branch details (name, address) by branch id PUT /branches/{branch_id}


# create new branch
