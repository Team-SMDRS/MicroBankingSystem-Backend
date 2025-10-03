# Branch routes - API endpoints for branch operations

from fastapi import APIRouter, Depends, Request
from typing import List

# Add UpdateBranchInput import
from app.schemas.branch_schema import BranchResponse, UpdateBranch, CreateBranch
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
@router.put("/branches/{branch_id}")
def update_branch(branch_id: str, update_data: UpdateBranch, request: Request, db=Depends(get_db)):
    repo = BranchRepository(db)
    current_user_id = request.state.user.get("user_id")
    updated = repo.update_branch(
        branch_id, update_data.dict(exclude_unset=True), current_user_id)
    if updated is None:
        return {"detail": "No valid fields to update."}
    return updated if updated else {"detail": "Branch not found or not updated."}

# create new branch


@router.post("/branches")
def create_branch(branch_data: CreateBranch, request: Request, db=Depends(get_db)):
    repo = BranchRepository(db)
    current_user_id = request.state.user.get("user_id")
    created_branch = repo.create_branch(branch_data, current_user_id)
    return created_branch
