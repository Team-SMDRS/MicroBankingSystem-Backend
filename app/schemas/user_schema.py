# manage users (view, create)

from pydantic import BaseModel
from typing import Optional

class RegisterUser(BaseModel):
    nic: str
    first_name: str
    last_name: str
    address: str
    phone_number: str
    username: str
    password: str

class LoginUser(BaseModel):
    username: str
    password: str
