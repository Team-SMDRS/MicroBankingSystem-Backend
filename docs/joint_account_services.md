# Create joint account for exsisting customers

curl -X 'POST' \
  'http://127.0.0.1:8000/api/joint-account/joint-account/create' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NjAwMzk1MzJ9.3TwCwmESsYwJHis8KPCU2vCt_Nn3tFEqBkVqgzitKts' \
  -H 'Content-Type: application/json' \
  -d '{
  "nic1": "200147897589",
  "nic2": "211454546587",
  "savings_plan_id": "7d8f328d-650d-4e19-b2ef-4c7292f6264a",
  "balance": 770
}'

	
Response body
Download
{
  "acc_id": "5f057bac-fb30-4d06-8ea7-ec7140d50574",
  "account_no": 6556060341
}

# Create joint account for new customers (both new)

curl -X 'POST' \
  'http://127.0.0.1:8000/api/joint-account/joint-account/create-with-new-customers' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NjAwNDAzNzN9.nk_P0vTaCxOeP3YAYexxN_AzGR8_K77MrT1caxyFHVE' \
  -H 'Content-Type: application/json' \
  -d '{
  "customer1": {
    "full_name": "customer15",
    "address": "Kaluthara",
    "phone_number": "0778866489",
    "nic": "200234569111",
    "dob": "2002-01-03"
  },
  "customer2": {
    "full_name": "customer15",
    "address": "Kaluthara",
    "phone_number": "0712233489",
    "nic": "200011224111",
    "dob": "2000-09-30"
  },
  "savings_plan_id": "7d8f328d-650d-4e19-b2ef-4c7292f6264a",
  "balance": 11130
}'


	
{
  "customer1": {
    "customer_id": "5d8377c5-620c-41c9-9bd5-8c9e6092c5fd",
    "nic": "200234569111",
    "username": "customer151008",
    "password": "YW80m5ES"
  },
  "customer2": {
    "customer_id": "91150ead-dfb9-412c-91b5-672b6aa4edfd",
    "nic": "200011224111",
    "username": "customer157671",
    "password": "oHreVv3w"
  },
  "acc_id": "f4fd7d5b-3223-495a-8343-c65abbd888a9",
  "account_no": 3280502923
}


# Create joint account for new customer and a exsisting customer

curl -X 'POST' \
  'http://127.0.0.1:8000/api/joint-account/joint-account/create-with-existing-and-new-customer' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMiIsInVzZXJfaWQiOiI2Yjk5NzIxNy05Y2U1LTRkZGEtYTlhZS04N2JmNTg5YjkyYTUiLCJleHAiOjE3NjAwMzk1MzJ9.3TwCwmESsYwJHis8KPCU2vCt_Nn3tFEqBkVqgzitKts' \
  -H 'Content-Type: application/json' \
  -d '{
  "existing_customer_nic": "211454546587",
  "new_customer": {
    "full_name": "customer12",
    "address": "Gampaha",
    "phone_number": "0786633482",
    "nic": "200188340025",
    "dob": "2001-02-26"
  },
  "savings_plan_id": "7d8f328d-650d-4e19-b2ef-4c7292f6264a",
  "balance": 4440
}'


	
Response body
Download
{
  "existing_customer_id": "97da5431-f39a-43e5-b0cd-9d185327b6e6",
  "new_customer_id": "73bd4ecf-69f1-442b-98d0-b370aff34051",
  "acc_id": "f54ebeb2-6867-4805-85e6-0f723109bfbf",
  "account_no": 2531415443,
  "new_customer_login": {
    "username": "customer129765",
    "password": "6VCtZuvo"
  }
}