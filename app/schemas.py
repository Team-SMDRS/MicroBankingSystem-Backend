from pydantic import BaseModel

class CustomerSchema(BaseModel):
    customer_id: int
    first_name: str
    last_name: str
    email: str
    phone_number: str | None = None
    address: str | None = None

    class Config:
        orm_mode = True  # if Pydantic v2: from_attributes = True
