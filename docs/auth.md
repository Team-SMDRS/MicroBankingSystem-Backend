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
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMSIsInVzZXJfaWQiOiJkZTlkYzUzMS0xMWJmLTQ0ODEtODgyYS1kYzMyOTE1ODBmNjAiLCJleHAiOjE3NTg1MTUzMzF9.HV9HtQ75k9NZ7Hb199Lo6ddNnAHWDW92zrIjG0Q72Qk",
  "refresh_token": "_DY5i-8Q9ErKKBMT-YH3wurg5EpPqBvIsgMhrwwZT4Y",
  "token_type": "Bearer",
  "expires_in": "2025-09-29T03:58:51.847145",
  "user_id": "de9dc531-11bf-4481-882a-dc3291580f60",
  "username": "user1"
}