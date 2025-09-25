from fastapi import Request, HTTPException, Depends
from fastapi.responses import JSONResponse
from datetime import datetime
from app.core.utils import decode_access_token_for_customer


async def customer_auth_dependency(request: Request):
    # Extract and validate Authorization header
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid authorization customers header")

    token = auth_header.split(" ")[1]

    # Decode and validate token
    payload = decode_access_token_for_customer(token)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid or expired customers  access token")

    # Check token expiration
    if "exp" in payload:
        if datetime.utcnow().timestamp() > payload["exp"]:
            raise HTTPException(status_code=401, detail=" customers  Access token  expired")

    customer_id = payload.get("customer_id")
    if not customer_id:
        raise HTTPException(status_code=401, detail="Invalid token payload customers ")

    # Attach customer data to request.state
    request.state.customer = payload
    request.state.customer["customer_id"] = customer_id
    return payload
