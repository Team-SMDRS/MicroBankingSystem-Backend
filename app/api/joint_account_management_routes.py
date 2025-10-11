from app.schemas.joint_account_management_schema import JointAccountWithExistingAndNewCustomerRequest

from app.schemas.joint_account_management_schema import JointAccountWithNewCustomersRequest

from fastapi import APIRouter, Depends, HTTPException, Request
from app.schemas.joint_account_management_schema import JointAccountCreateRequest, JointAccountWithExistingAndNewCustomerRequest
from app.services.joint_account_management_service import JointAccountManagementService
from app.database.db import get_db
from uuid import UUID

router = APIRouter()

@router.post("/joint-account/create")
def create_joint_account(request_body: JointAccountCreateRequest, request: Request, db=Depends(get_db)):
	# Get user_id from request.state.user (set by auth middleware)
	user = getattr(request.state, "user", None)
	user_id = user["user_id"] if user and "user_id" in user else None
	if not user_id:
		raise HTTPException(status_code=401, detail="User not authenticated")
	try:
		user_uuid = UUID(str(user_id))
	except Exception:
		raise HTTPException(status_code=400, detail="user_id must be a valid UUID string")
	service = JointAccountManagementService(db)
	account_data = {
		"savings_plan_id": request_body.savings_plan_id,
		"balance": request_body.balance
	}
	result = service.create_joint_account(account_data, request_body.nic1, request_body.nic2, str(user_uuid))
	if not result:
		raise HTTPException(status_code=404, detail="One or both customers not found")
	acc_id, account_no = result
	return {"acc_id": acc_id, "account_no": account_no}


@router.post("/joint-account/create-with-new-customers")
def create_joint_account_with_new_customers(request_body: JointAccountWithNewCustomersRequest, request: Request, db=Depends(get_db)):
	user = getattr(request.state, "user", None)
	user_id = user["user_id"] if user and "user_id" in user else None
	if not user_id:
		raise HTTPException(status_code=401, detail="User not authenticated")
	service = JointAccountManagementService(db)
	result = service.create_joint_account_with_new_customers(
		request_body.customer1.dict(),
		request_body.customer2.dict(),
		{"savings_plan_id": request_body.savings_plan_id, "balance": request_body.balance},
		user_id
	)
	if not result:
		raise HTTPException(status_code=400, detail="Could not create joint account for new customers")
	# result contains customer1, customer2, acc_id, account_no
	return {
		"customer1": result["customer1"],
		"customer2": result["customer2"],
		"acc_id": result["acc_id"],
		"account_no": result["account_no"]
	}

@router.post("/joint-account/create-with-existing-and-new-customer")
def create_joint_account_with_existing_and_new_customer(request_body: JointAccountWithExistingAndNewCustomerRequest, request: Request, db=Depends(get_db)):
	user = getattr(request.state, "user", None)
	user_id = user["user_id"] if user and "user_id" in user else None
	if not user_id:
		raise HTTPException(status_code=401, detail="User not authenticated")
	service = JointAccountManagementService(db)
	result = service.create_joint_account_with_existing_and_new_customer(
		request_body.existing_customer_nic,
		request_body.new_customer.dict(),
		{"savings_plan_id": request_body.savings_plan_id, "balance": request_body.balance},
		user_id
	)
	if not result:
		raise HTTPException(status_code=400, detail="Could not create joint account for existing and new customer")
	existing_customer_id, new_customer_id, acc_id, account_no, username, password = result
	return {
		"existing_customer_id": existing_customer_id,
		"new_customer_id": new_customer_id,
		"acc_id": acc_id,
		"account_no": account_no,
		"new_customer_login": {
			"username": username,
			"password": password
		}
	}
