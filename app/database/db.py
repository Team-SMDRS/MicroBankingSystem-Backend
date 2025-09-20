 # get_db() → psycopg2 connection context manager


import psycopg2
from psycopg2.extras import RealDictCursor
import os
from dotenv import load_dotenv

load_dotenv()

def get_db():
    


    conn = psycopg2.connect(
    dbname=os.getenv("POSTGRES_DB", "microbanking"),
    user=os.getenv("POSTGRES_USER", "postgres"),
    password=os.getenv("POSTGRES_PASSWORD", "postgres"),
    host=os.getenv("POSTGRES_HOST", "db"),   # <-- IMPORTANT: 'db' is the service name
    port=os.getenv("POSTGRES_PORT", "5432"),
    cursor_factory=RealDictCursor
    )

    return conn
