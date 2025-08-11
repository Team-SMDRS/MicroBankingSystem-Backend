from app.db import engine, Base
from app.models import Customer, User

# Create all tables based on Base metadata
Base.metadata.create_all(bind=engine)

print("Tables created!")
