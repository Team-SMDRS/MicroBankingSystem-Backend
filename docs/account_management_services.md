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


# Get all account details

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/accounts/all' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4MTIzODZ9.bpHFbCg-8qvUMnbf7RM12cXxPSCBBsnyKvAZR4RV2do'

	
Response body

[
  {
    "acc_id": "45645f9e-b7cd-4b83-b940-bd8c4085b1b1",
    "account_no": 2588679594,
    "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
    "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
    "balance": 6670,
    "opened_date": "2025-09-24T19:56:30.316783",
    "created_at": "2025-09-24T19:56:30.316783",
    "updated_at": "2025-09-24T19:56:30.316783",
    "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
    "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
    "status": "active"
  },
  {
    "acc_id": "134c8d94-65fe-410e-829b-9f74927f0562",
    "account_no": 6676879012,
    "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
    "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
    "balance": 1000,
    "opened_date": "2025-09-24T19:55:55.612410",
    "created_at": "2025-09-24T19:55:55.612410",
    "updated_at": "2025-09-24T19:55:55.612410",
    "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
    "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
    "status": "active"
  }
]


# Get account owner details by account number

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/account/123456789/owner' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4NDU0NDZ9.qto9Sw3JqbQXe7SMjzH9_sJvLhc6wXWWVIYHzIOVE_s'

	
	
Response body
Download
[
  {
    "customer_id": "96a6ea17-b2d3-40d0-9c5b-903da6280f50",
    "full_name": "customer 1",
    "address": "jafna",
    "phone_number": "0724548799",
    "nic": "200454546545",
    "created_at": "2025-09-18T14:29:18.039149",
    "updated_at": "2025-09-18T14:33:26.652769",
    "created_by": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09",
    "updated_by": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09",
    "dob": "2001-02-06"
  },
  {
    "customer_id": "f0bf0ef8-0015-4c79-bae4-bab26d897409",
    "full_name": "customer 2",
    "address": "jafna",
    "phone_number": "0756548799",
    "nic": "200725457898",
    "created_at": "2025-09-18T14:29:55.137535",
    "updated_at": "2025-09-18T14:33:26.654507",
    "created_by": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09",
    "updated_by": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09",
    "dob": "2001-02-06"
  }
]


# Get account balance by account number

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/account/balance/1111111111' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4MTIzODZ9.bpHFbCg-8qvUMnbf7RM12cXxPSCBBsnyKvAZR4RV2do'

  	
Response body
Download
{
  "account_no": "1111111111",
  "balance": 3000
}



# Get accounts details by nic

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/accounts/by-nic/200454546545' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4MTIzODZ9.bpHFbCg-8qvUMnbf7RM12cXxPSCBBsnyKvAZR4RV2do'

	
Response body
Download
[
  {
    "acc_id": "fb7b432f-634b-4b7c-9ee5-f4ba4a38f531",
    "account_no": 123456789,
    "branch_id": "57438d7f-184f-42fe-b0d6-91a2ef609beb",
    "savings_plan_id": "7d8f328d-650d-4e19-b2ef-4c7292f6264a",
    "balance": 2000,
    "opened_date": "2025-09-18T14:07:15.807623",
    "created_at": "2025-09-18T14:07:15.807623",
    "updated_at": "2025-09-18T14:26:16.479309",
    "created_by": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09",
    "updated_by": "780ba9d3-3c4d-40d6-b1a1-c0132f89df09",
    "status": "active"
  }
]



# Get all accounts details by branch_id

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/accounts/branch/3dd6870c-e6f2-414d-9973-309ba00ce115' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4MTIzODZ9.bpHFbCg-8qvUMnbf7RM12cXxPSCBBsnyKvAZR4RV2do'

	
Response body
Download
{
  "accounts": [
    {
      "acc_id": "45645f9e-b7cd-4b83-b940-bd8c4085b1b1",
      "account_no": 2588679594,
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
      "balance": 6670,
      "opened_date": "2025-09-24T19:56:30.316783",
      "created_at": "2025-09-24T19:56:30.316783",
      "updated_at": "2025-09-24T19:56:30.316783",
      "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "status": "active"
    },
    {
      "acc_id": "134c8d94-65fe-410e-829b-9f74927f0562",
      "account_no": 6676879012,
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
      "balance": 1000,
      "opened_date": "2025-09-24T19:55:55.612410",
      "created_at": "2025-09-24T19:55:55.612410",
      "updated_at": "2025-09-24T19:55:55.612410",
      "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "status": "active"
    },
    {
      "acc_id": "58f8da96-a4c1-4071-8a8c-a195b70bb040",
      "account_no": 2815823974,
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
      "balance": 101,
      "opened_date": "2025-09-24T17:50:34.479023",
      "created_at": "2025-09-24T17:50:34.479023",
      "updated_at": "2025-09-24T17:50:34.479023",
      "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "status": "active"
    },
    {
      "acc_id": "c1e74ae4-f466-4769-9649-f8064a7e6a89",
      "account_no": 6052845866,
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
      "balance": 105,
      "opened_date": "2025-09-24T14:56:44.494199",
      "created_at": "2025-09-24T14:56:44.494199",
      "updated_at": "2025-09-24T14:56:44.494199",
      "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "status": "active"
    },
    {
      "acc_id": "3337ad45-7e90-4c8f-9057-e38f3c43f196",
      "account_no": 1111111111,
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
      "balance": 3000,
      "opened_date": "2025-09-18T14:43:34.844831",
      "created_at": "2025-09-18T14:43:34.844831",
      "updated_at": "2025-09-18T14:43:34.844831",
      "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "status": "active"
    },
    {
      "acc_id": "1b337986-ae2d-4e9e-9f87-5bd92e29253f",
      "account_no": 1234567890,
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "savings_plan_id": "3578bd55-8c57-4757-aa7b-0f37b859edd6",
      "balance": 1000,
      "opened_date": "2025-09-18T13:56:05.448161",
      "created_at": "2025-09-18T13:56:05.448161",
      "updated_at": "2025-09-18T14:07:15.810099",
      "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
      "status": "active"
    }
  ],
  "total_count": 6
}



# Update customer details 

curl -X 'PUT' \
  'http://127.0.0.1:8000/api/account-management/customer/91124bc9-de3b-49ae-bae7-d167281dbff0' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTg4MTIzODZ9.bpHFbCg-8qvUMnbf7RM12cXxPSCBBsnyKvAZR4RV2do' \
  -H 'Content-Type: application/json' \
  -d '{
  "full_name": "customer8",
  "address": "string",
  "phone_number": "string",
  "nic": "200233445512"
}'

	
Response body
Download
{
  "customer_id": "91124bc9-de3b-49ae-bae7-d167281dbff0",
  "full_name": "customer8",
  "address": "string",
  "phone_number": "string",
  "nic": "200233445512",
  "created_at": "2025-09-24T19:55:55.612410",
  "updated_at": "2025-09-25T15:52:21.916834",
  "created_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
  "updated_by": "6b997217-9ce5-4dda-a9ae-87bf589b92a5",
  "dob": "2003-01-02"
}


# Get account count for a branch 

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/accounts/branch/3dd6870c-e6f2-414d-9973-309ba00ce115/count' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTk0NTEyNDF9.h7OH00j4isR2Tifcf4JnoZz2MFS5z3FfkhCifGeXqKE'

Response body
Download
{
  "branch_name": "Colombo",
  "account_count": 6
}


# Get all account count 

curl -X 'GET' \
  'http://127.0.0.1:8000/api/account-management/accounts/count' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTk0NTEyNDF9.h7OH00j4isR2Tifcf4JnoZz2MFS5z3FfkhCifGeXqKE'

Response body
Download
{
  "account_count": 7
}


# create a savings plan

curl -X 'POST' \
  'http://127.0.0.1:8000/api/account-management/savings_plan/create' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NTk0NTEyNDF9.h7OH00j4isR2Tifcf4JnoZz2MFS5z3FfkhCifGeXqKE' \
  -H 'Content-Type: application/json' \
  -d '{
  "plan_name": "string",
  "interest_rate": 0
}'

Response body
Download
{
  "savings_plan_id": "edc304b9-e5ce-4bc0-8e0f-e015e6c7823c"
}
