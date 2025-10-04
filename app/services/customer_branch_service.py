
import string
from fastapi import HTTPException
from app.schemas.customer_branch_schema import CustomerNameID


class CustomerBranchService:

    def __init__(self, repo):
        self.repo = repo

    def get_all_customers(self):
        data = self.repo.get_all_customers()
        return [
            CustomerNameID(
                name=item["full_name"],        # dict-style access
                customer_id=item["customer_id"],
                nic=item["nic"]
            )
            for item in data
        ]

    def get_customers_by_branch(self, branch_id: str):
        data = self.repo.get_customers_by_users_branch(branch_id)
        return [
            CustomerNameID(
                name=item["full_name"],
                customer_id=item["customer_id"],
                nic=item["nic"]
            )
            for item in data
        ]

