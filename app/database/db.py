# get_db() → psycopg2 connection context manager


import psycopg2
from psycopg2.extras import RealDictCursor
import os
from dotenv import load_dotenv

load_dotenv()


def get_db():
    try:
        conn = psycopg2.connect(
            dbname=os.getenv("DB_NAME", "microbanking"),
            user=os.getenv("DB_USER", "postgres"),
            password=os.getenv("DB_PASSWORD", "postgres"),
            host=os.getenv("DB_HOST", "db"),   # <-- use localhost
            port=os.getenv("DB_PORT", "5432"),
            cursor_factory=RealDictCursor
        )
        print("Database connection established successfully.")
        return conn
    except Exception as e:
        print(f"Failed to connect to the database: {e}")
        raise
