# Branch service - Business logic for branch operations

from fastapi import HTTPException


class BranchService:
    def __init__(self, repo):
        self.repo = repo

    def get_all_branches(self):
        """Get all branches from the database"""
        try:
            branches = self.repo.get_all_branches()
            return branches
        except Exception as e:
            raise HTTPException(
                status_code=500, detail="Failed to retrieve branches")

    def get_branch_by_id(self, branch_id):
        """Get a branch by its ID"""
        try:
            branch = self.repo.get_branch_by_id(branch_id)
            if not branch:
                raise HTTPException(status_code=404, detail="Branch not found")
            return branch
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(
                status_code=500, detail="Failed to retrieve branch by ID")

    def get_branch_by_name(self, branch_name):
        """Get a branch by its name"""
        try:
            branch = self.repo.get_branch_by_name(branch_name)
            if not branch:
                raise HTTPException(status_code=404, detail="Branch not found")
            return branch
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(
                status_code=500, detail="Failed to retrieve branch by name")
