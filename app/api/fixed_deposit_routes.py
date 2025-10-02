# Fixed Deposit routes - API endpoints for fixed deposit operations

from fastapi import APIRouter, Depends
from typing import List

from app.schemas.fixed_deposit_schema import FixedDepositResponse
from app.database.db import get_db
from app.repositories.fixed_deposit_repo import FixedDepositRepository
from app.services.fixed_deposit_service import FixedDepositService

router = APIRouter()

@router.get("/fixed-deposits", response_model=List[FixedDepositResponse])
def get_all_fixed_deposits(db=Depends(get_db)):
    """Get all fixed deposit accounts"""
    repo = FixedDepositRepository(db)
    service = FixedDepositService(repo)
    return service.get_all_fixed_deposits()
