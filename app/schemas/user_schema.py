# manage users (view, create) 
# this schema is used for validation

from pydantic import BaseModel
from typing import Optional, List
from uuid import UUID

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

class ManageUserRoles(BaseModel):
    user_id: str
    role_ids: List[str]

class UserResponse(BaseModel):
    user_id: str
    nic: Optional[str]
    first_name: str
    last_name: str
    address: Optional[str]
    phone_number: Optional[str]
    dob: Optional[str]
    email: Optional[str]
    created_at: str

class RoleResponse(BaseModel):
    role_id: str
    role_name: str

class UserWithRoles(BaseModel):
    user_id: str
    nic: Optional[str]
    first_name: str
    last_name: str
    roles: List[RoleResponse]

class UpdatePasswordRequest(BaseModel):
    old_password: str
    new_password: str
    
class UpdateUserRequest(BaseModel):
    user_id: str
    first_name: str
    last_name: str
    phone_number: str
    address: str
    email: Optional[str] = None
    
class DeactivateUserRequest(BaseModel):
    user_id: str
    
class ActivateUserRequest(BaseModel):
    user_id: str

class PasswordResetRequest(BaseModel):
    username: str
    new_password: str
    
class AssignUserToBranchRequest(BaseModel):
    user_id: str
    branch_id: str
