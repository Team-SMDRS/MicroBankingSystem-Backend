from fastapi import APIRouter, Depends, HTTPException, Request
from app.database.db import get_db
from app.repositories.branch_stats_repo import BranchStatsRepository
from app.services.branch_stats_service import BranchStatsService
from app.schemas.branch_stats_schema import BranchAccountStats, BranchListResponse

router = APIRouter()

def get_branch_stats_service(db=Depends(get_db)) -> BranchStatsService:
    """Dependency to get BranchStatsService instance"""
    branch_stats_repo = BranchStatsRepository(db)
    return BranchStatsService(branch_stats_repo)

def get_current_user(request: Request):
    """Simple dependency to get current authenticated user from request state"""
    if not hasattr(request.state, 'user') or not request.state.user:
        raise HTTPException(status_code=401, detail="Authentication required")
    return request.state.user

@router.get("/branches/list", response_model=BranchListResponse)
def get_all_branches(
    current_user: dict = Depends(get_current_user),
    branch_stats_service: BranchStatsService = Depends(get_branch_stats_service)
):
    """
    Get list of all branches for dropdown selection
    
    Returns:
    - List of branches with branch_id, branch_name, branch_code, city
    - Total count of branches
    
    This endpoint is useful for populating dropdown menus
    """
    return branch_stats_service.get_all_branches_list()

@router.get("/branches/{branch_id}/statistics", response_model=BranchAccountStats)
def get_branch_account_statistics(
    branch_id: str,
    current_user: dict = Depends(get_current_user),
    branch_stats_service: BranchStatsService = Depends(get_branch_stats_service)
):
    """
    Get comprehensive account statistics for a specific branch
    
    Returns statistics for:
    - **Joint Accounts**: Total count and combined balance
    - **Fixed Deposits**: Total count and combined amount
    - **Savings/Current Accounts**: Total count and combined balance (excluding joint accounts)
    
    Parameters:
    - **branch_id**: UUID of the branch
    
    Example Response:
    ```json
    {
        "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
        "branch_name": "Main Branch",
        "branch_code": "BR001",
        "total_joint_accounts": 5,
        "joint_accounts_balance": 250000.00,
        "total_fixed_deposits": 10,
        "fixed_deposits_amount": 1500000.00,
        "total_savings_accounts": 25,
        "savings_accounts_balance": 750000.00
    }
    ```
    """
    return branch_stats_service.get_branch_statistics(branch_id)
