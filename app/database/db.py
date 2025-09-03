 # get_db() → psycopg2 connection context manager


import psycopg2
from psycopg2.extras import RealDictCursor
import os
from dotenv import load_dotenv

load_dotenv()

def get_db():
    conn = psycopg2.connect(
        dbname=os.getenv("DB_NAME", "bankdata"),
        user=os.getenv("DB_USER", "microbank"),
        password=os.getenv("DB_PASSWORD", "databus"),
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        cursor_factory=RealDictCursor
    )
    return conn
