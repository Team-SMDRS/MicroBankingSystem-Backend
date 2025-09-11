# Register 

- request 
curl -X 'POST' \
  'http://127.0.0.1:8000/register' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "nic": "200124521426",
  "first_name": "string",
  "last_name": "string",
  "address": "string",
  "phone_number": "0760848755",
  "username": "sangeeth",
  "password": "111111"
}'
- response
{
  "msg": "User registered",
  "user_id": "57fd929b-f792-4036-aab3-e9a9ad22f81e"
}

# Login
- request 
- curl -X 'POST' \
  'http://127.0.0.1:8000/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "username": "sangeeth",
  "password": "111111"
}'

-response 

{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzYW5nZWV0aCIsInVzZXJfaWQiOiI1N2ZkOTI5Yi1mNzkyLTQwMzYtYWFiMy1lOWE5YWQyMmY4MWUiLCJleHAiOjE3NTc1NTc2MTF9.0NZedQZRyd-e34T_qIIIN-VLdf3gTJMpciGUEG7z0So",
  "token_type": "Bearer"
}

