# Create account for a new customer with customer login

http://127.0.0.1:8000/api/account-management/register_customer_with_account

curl -X 'POST' \
  'http://127.0.0.1:8000/api/account-management/register_customer_with_account' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg3MTUwNDl9.EKOnjWN11UOPMABp4xh92STpQcyKTCnXfRWqv0SoP2o' \
  -H 'Content-Type: application/json' \
  -d '{
  "full_name": "string",
  "address": "string",
  "phone_number": "string",
  "nic": "20024545785",
  "dob": "1001-10-11",
  "balance": 20,
  "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
  "status": "active"
}'

{
  "msg": "Customer registered and account created",
  "customer_id": "6e97c67f-5838-4137-95ad-99f1b1919de5",
  "username": "string8854",
  "password": "7uou4WVF",
  "account_no": 1341693476
}




# Create account for a exisiting customer

curl -X 'POST' \
  'http://127.0.0.1:8000/api/account-management/existing_customer/open_account' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg3MzMwOTJ9.HCYcKt8dI3yD4vb1tuXUxSM-c7MxDtYddl3dHpHAGp0' \
  -H 'Content-Type: application/json' \
  -d '{
  "nic": "string",
  "balance": 310,
  "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6"

  }
  	
Response body

{
  "msg": "Account created for existing customer",
  "acc_id": "376f166e-5ec9-4c54-a7b8-057b0c753dcb",
  "account_no": "9341035245"
}

# Get account details by account number
curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/account/details/1111111111' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4MTIzODZ9.bpHFbCg-8qvUMnbf7RM12cXxPSCBBsnyKvAZR4RV2do'

Response body
Download
{
  "customer_name": "customer 4",
  "account_id": "3337ad45-7e90-4c8f-9057-e38f3c43f196",
  "branch_name": "Colombo",
  "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
  "balance": 3000,
  "account_type": "Adult"
}