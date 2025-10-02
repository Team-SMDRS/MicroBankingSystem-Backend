
import string
from fastapi import HTTPException
from app.schemas.customer_branch_schema import CustomerCount, CustomerNameID


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

    def get_customers_count(self):
        count = self.repo.get_customers_count()
        if count is None:
            raise HTTPException(status_code=404, detail="No customers found")
        return CustomerCount(count=count)

    def get_customers_count_by_branch(self, branch_id: str):
        count = self.repo.get_customers_count_by_branch(branch_id)
        if count is None:
            raise HTTPException(
                status_code=404, detail="No customers found in this branch")
        return CustomerCount(count=count)
