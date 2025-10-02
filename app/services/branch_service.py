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
            raise HTTPException(status_code=500, detail="Failed to retrieve branches")