from pydantic import BaseModel


from typing import Optional

class LoginCustomer(BaseModel):
    username: str
    password: str

