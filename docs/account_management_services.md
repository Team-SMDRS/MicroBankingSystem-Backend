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




