from fastapi import APIRouter, Depends, Request
from app.schemas.joint_account_management_schema import (
    JointAccountCreateRequest,
    JointAccountWithNewCustomersRequest,
    JointAccountWithExistingAndNewCustomerRequest,
)
from app.services.joint_account_management_service import JointAccountManagementService
from app.database.db import get_db

router = APIRouter()


@router.post("/joint-account/create")
def create_joint_account(request_body: JointAccountCreateRequest, request: Request, db=Depends(get_db)):
    user = getattr(request.state, "user", None)
    user_id = user["user_id"] if user and "user_id" in user else None

    service = JointAccountManagementService(db)
    # Only pass balance - service will handle savings plan ID internally
    account_data = {"balance": request_body.balance}
    result = service.create_joint_account(account_data, request_body.nic1, request_body.nic2, user_id)
    return {"acc_id": result[0], "account_no": result[1]}


@router.post("/joint-account/create-with-new-customers")
def create_joint_account_with_new_customers(request_body: JointAccountWithNewCustomersRequest, request: Request, db=Depends(get_db)):
    user = getattr(request.state, "user", None)
    user_id = user["user_id"] if user and "user_id" in user else None

    service = JointAccountManagementService(db)
    # Only pass balance - service will handle savings plan ID internally
    account_data = {"balance": request_body.balance}
    result = service.create_joint_account_with_new_customers(
        request_body.customer1.dict(),
        request_body.customer2.dict(),
        account_data,
        user_id
    )
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

    service = JointAccountManagementService(db)
    # Only pass balance - service will handle savings plan ID internally
    account_data = {"balance": request_body.balance}
    result = service.create_joint_account_with_existing_and_new_customer(
        request_body.existing_customer_nic,
        request_body.new_customer.dict(),
        account_data,
        user_id
    )
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
