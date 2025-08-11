from fastapi import FastAPI
from  app.routers import customer

app = FastAPI()

app.include_router(customer.router)
