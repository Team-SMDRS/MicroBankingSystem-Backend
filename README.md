
## A simple backend for a microbanking system built with **FastAPI**, PostgreSQL, 
### 1️⃣ Clone the repository
### 2️⃣ Create a virtual environment
 ``` bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

### 3️⃣ Install dependencies
```  bash
pip install -r requirements.txt
```
### 4️⃣ Configure environment variables
Create a .env file in the project root:
``` bash
DATABASE_URL=postgresql://username:password@localhost:5432/databaseName
SECRET_KEY=your-secret-key-here
```
### 5️⃣ Create the database tables
``` bash
python -m app.create_tables.py
```
### 6️⃣ Run the FastAPI app
``` bash
uvicorn app.main:app --reload
```
Your API will be available at:http://127.0.0.1:8000

