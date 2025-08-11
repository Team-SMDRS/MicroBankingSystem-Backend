from app.db import engine, Base
from app.models import Customer

Base.metadata.create_all(bind=engine)

print("Tables created!")
