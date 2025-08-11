from sqlalchemy.orm import Session
from ..models import Customer

def get_all_customers(db: Session):
    return db.query(Customer).all()
