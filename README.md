# 🏦 BTrust Banking System

A modern microbanking backend built with FastAPI, PostgreSQL, and JWT authentication.

## 🎬 Demo Video

[![BTrust Banking System Demo](https://img.youtube.com/vi/HFerK6FWCj8/maxresdefault.jpg)](https://youtu.be/HFerK6FWCj8)

**Watch Demo:** https://youtu.be/HFerK6FWCj8

## Quick Start

### Option 1: Docker (Recommended)

```bash
git clone <your-repo-url>
cd MicroBankingSystem-Backend
docker compose up --build
```

**Access:** http://localhost:8000/docs

### Option 2: Manual Setup

```bash
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

**Access:** http://127.0.0.1:8000/docs

## Features

- 🔐 JWT Authentication & Role-Based Access Control
- 👥 Account Management (Savings, Current, Joint Accounts)
- 💳 Transaction Processing & Transfers
- 📊 Fixed Deposits & Savings Plans
- 📈 Branch Management & Analytics
- 📄 PDF Report Generation
- 🏢 Multi-Branch Support

## Tech Stack

- **Framework:** FastAPI
- **Database:** PostgreSQL
- **Authentication:** JWT + Bcrypt
- **ORM:** SQLAlchemy

## Project Structure

```
app/
  ├── api/              # Route handlers
  ├── repositories/     # Data access layer
  ├── services/         # Business logic
  ├── schemas/          # Request/Response models
  ├── middleware/       # Auth & permissions
  └── database/         # Database connection
schema/                 # Database migrations
tests/                  # Test suite
```

## API Endpoints

- `POST /api/auth/login` - Login
- `GET/POST /api/account-management` - Account operations
- `POST /api/transaction` - Transfer funds
- `POST /api/fixed-deposit` - Create fixed deposit
- `POST /api/savings-plan` - Create savings plan
- `GET /api/branch` - Branch information
- `GET /api/overview` - Dashboard & reports

See `/docs` for full API documentation.

## Environment Setup

Create `.env` file:
```
DB_HOST=localhost
DB_PORT=5432
DB_NAME=btrust_bank
DB_USER=postgres
DB_PASSWORD=your_password
JWT_SECRET=your_secret_key
```

## Contributing

Contributions are welcome! Please follow PEP 8 style guidelines and add tests for new features.

---

**Built with ❤️ by Team SMDRS**
