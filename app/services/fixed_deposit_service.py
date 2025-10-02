# Fixed Deposit service - Business logic for fixed deposit operations

from fastapi import HTTPException

class FixedDepositService:
    def __init__(self, repo):
        self.repo = repo

    def get_all_fixed_deposits(self):
        """Get all fixed deposit accounts from the database"""
        try:
            fixed_deposits = self.repo.get_all_fixed_deposits()
            return fixed_deposits
        except Exception as e:
            raise HTTPException(status_code=500, detail="Failed to retrieve fixed deposits")
