
from pydantic import BaseModel
from typing import Optional

class NewCustomerData(BaseModel):
	full_name: str
	address: Optional[str] = None
	phone_number: Optional[str] = None
	nic: str
	dob: str

class JointAccountWithNewCustomersRequest(BaseModel):
	customer1: NewCustomerData
	customer2: NewCustomerData
	savings_plan_id: str
	balance: Optional[float] = 0.0
	"""
	Request schema for creating a joint account with two new customers.
	Response will include both customers' NIC, username, and password for identification.
	"""


class JointAccountCreateRequest(BaseModel):
	nic1: str
	nic2: str
	savings_plan_id: str
	balance: Optional[float] = 0.0
	

class JointAccountWithExistingAndNewCustomerRequest(BaseModel):
	existing_customer_nic: str
	new_customer: NewCustomerData
	savings_plan_id: str
	balance: Optional[float] = 0.0
