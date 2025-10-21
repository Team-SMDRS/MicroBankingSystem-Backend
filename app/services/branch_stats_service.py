from fastapi import HTTPException
from app.repositories.branch_stats_repo import BranchStatsRepository
from app.schemas.branch_stats_schema import BranchAccountStats, BranchListResponse, BranchListItem

class BranchStatsService:
    def __init__(self, branch_stats_repo: BranchStatsRepository):
        self.branch_stats_repo = branch_stats_repo

    def get_branch_statistics(self, branch_id: str) -> BranchAccountStats:
        """
        Get comprehensive statistics for a branch including:
        - Joint accounts count and balance
        - Fixed deposits count and amount
        - Savings accounts count and balance
        """
        try:
            stats = self.branch_stats_repo.get_branch_account_statistics(branch_id)
            
            if not stats:
                raise HTTPException(
                    status_code=404,
                    detail=f"Branch with ID {branch_id} not found"
                )
            
            return BranchAccountStats(
                branch_id=stats['branch_id'],
                branch_name=stats['branch_name'],
                branch_code=stats.get('branch_code'),
                total_joint_accounts=stats['total_joint_accounts'],
                joint_accounts_balance=stats['joint_accounts_balance'],
                total_fixed_deposits=stats['total_fixed_deposits'],
                fixed_deposits_amount=stats['fixed_deposits_amount'],
                total_savings_accounts=stats['total_savings_accounts'],
                savings_accounts_balance=stats['savings_accounts_balance']
            )
            
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(
                status_code=500,
                detail=f"Error fetching branch statistics: {str(e)}"
            )

    def get_all_branches_list(self) -> BranchListResponse:
        """
        Get list of all branches for dropdown selection
        """
        try:
            branches_data = self.branch_stats_repo.get_all_branches()
            
            branches = [
                BranchListItem(
                    branch_id=branch['branch_id'],
                    branch_name=branch['branch_name'],
                    branch_code=branch.get('branch_code'),
                    city=branch.get('city')
                )
                for branch in branches_data
            ]
            
            return BranchListResponse(
                branches=branches,
                total_count=len(branches)
            )
            
        except Exception as e:
            raise HTTPException(
                status_code=500,
                detail=f"Error fetching branches list: {str(e)}"
            )
