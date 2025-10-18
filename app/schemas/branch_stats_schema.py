from pydantic import BaseModel, Field
from typing import Optional, List

class BranchAccountStats(BaseModel):
    """Statistics for different account types in a branch"""
    
    # Joint Accounts
    total_joint_accounts: int = Field(..., description="Total number of joint accounts")
    joint_accounts_balance: float = Field(..., description="Total balance in joint accounts")
    
    # Fixed Deposits
    total_fixed_deposits: int = Field(..., description="Total number of fixed deposit accounts")
    fixed_deposits_amount: float = Field(..., description="Total amount in fixed deposits")
    
    # Savings/Current Accounts
    total_savings_accounts: int = Field(..., description="Total number of savings/current accounts")
    savings_accounts_balance: float = Field(..., description="Total balance in savings accounts")
    
    # Branch Info
    branch_id: str
    branch_name: str
    branch_address: Optional[str] = None

class BranchListItem(BaseModel):
    """Branch information for dropdown"""
    branch_id: str
    branch_name: str
    branch_address: Optional[str] = None

class BranchListResponse(BaseModel):
    """List of all branches for dropdown"""
    branches: List[BranchListItem]
    total_count: int
