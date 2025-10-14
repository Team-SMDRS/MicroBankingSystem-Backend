from pydantic import BaseModel
from typing import Optional

# Input schema for creating a savings plan
class SavingsPlanCreate(BaseModel):
    plan_name: str
    interest_rate: float
    min_balance: Optional[float] = 0.0  # New field for minimum balance

    

