# manage users (view, create) 
# this schema is used for validation

from pydantic import BaseModel
from typing import Optional

class RegisterUser(BaseModel):
    nic: str
    first_name: str
    last_name: str
    address: str
    phone_number: str
    dob: str
    username: str
    password: str

class LoginUser(BaseModel):
    username: str
    password: str

