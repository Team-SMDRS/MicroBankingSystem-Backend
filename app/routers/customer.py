from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from typing import List

from ..schemas import CustomerSchema
from ..controllers.customer_controller import get_all_customers
from ..db import get_db

router = APIRouter(prefix="/customers", tags=["customers"])

@router.get("/", response_model=List[CustomerSchema])
def read_customers(db: Session = Depends(get_db)):
    return get_all_customers(db)
