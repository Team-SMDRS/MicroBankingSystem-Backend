
import string
from fastapi import HTTPException
from app.schemas.customer_branch_schema import CustomerCount, CustomerNameID, CustomerCountByBranch,  CustomersByBranchID


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
        return CustomerCountByBranch(branch_id=branch_id, count=count)

    def get_customers_count_by_branch_id(self, branch_id: str):
        count = self.repo.get_customers_count_by_branch_id(branch_id)
        if count is None:
            raise HTTPException(
                status_code=404, detail="No customers found in this branch")
        return CustomerCountByBranch(branch_id=branch_id, count=count)

    # get all customers of branch id
    def get_customers_by_branch_id(self, branch_id: str):
        data = self.repo.get_customers_by_branch_id(branch_id)
        return [
            CustomersByBranchID(
                customer_id=item["customer_id"],
                full_name=item["full_name"],
                nic=item["nic"],
                address=item["address"],
                phone_number=item["phone_number"]
            )
            for item in data
        ]

    # get count of all accounts in branch id
    def get_accounts_count_by_branch_id(self, branch_id: str):
        count = self.repo.get_accounts_count_by_branch_id(branch_id)
        if count is None:
            raise HTTPException(
                status_code=404, detail="No accounts found in this branch")
        return CustomerCount(count=count)

    # get total balance of all accounts in branch id
    def get_total_balance_by_branch_id(self, branch_id: str):
        total_balance = self.repo.get_total_balance_by_branch_id(branch_id)
        if total_balance is None:
            raise HTTPException(
                status_code=404, detail="No accounts found in this branch")
        return {"branch_id": branch_id, "total_balance": total_balance}
