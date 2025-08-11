from sqlalchemy.orm import Session
from ..services.customer_service import get_all_customers

def list_customers(db: Session):
    return get_all_customers(db)
