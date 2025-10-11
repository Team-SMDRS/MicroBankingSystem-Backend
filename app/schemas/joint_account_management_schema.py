
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
	balance: Optional[float] = 0.0
	"""
	Request schema for creating a joint account with two new customers.
	Response will include both customers' NIC, username, and password for identification.
	Savings plan ID is automatically set to 'Joint' by the service.
	"""


class JointAccountCreateRequest(BaseModel):
	nic1: str
	nic2: str
	balance: Optional[float] = 0.0
	"""
	Request schema for creating a joint account with existing customers.
	Savings plan ID is automatically set to 'Joint' by the service.
	"""
	

class JointAccountWithExistingAndNewCustomerRequest(BaseModel):
	existing_customer_nic: str
	new_customer: NewCustomerData
	balance: Optional[float] = 0.0
	"""
	Request schema for creating a joint account with one existing and one new customer.
	Savings plan ID is automatically set to 'Joint' by the service.
	"""
