
# 🏦 Micro Banking System Backend

A FastAPI backend for microbanking operations with JWT authentication and PostgreSQL database.

## 🐳 Quick Start with Docker (Recommended)

```bash
# Clone and navigate
git clone <your-repo-url>
cd MicroBankingSystem-Backend

# Build and run
docker compose up --build

# Stop services
docker compose down -v
```

**Access:** http://localhost:8000 | **Docs:** http://localhost:8000/docs

## 🔧 Manual Setup

```bash
# Setup environment
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt

# Create .env file with your database credentials as env.example 


# Initialize database and run

uvicorn app.main:app --reload
```

**Access:** http://127.0.0.1:8000