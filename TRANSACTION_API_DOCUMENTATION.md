# Transaction Management API Documentation

## Overview
This document describes the comprehensive Transaction Management API endpoints for the MicroBankingSystem. All endpoints require authentication via Bearer token.

## Base URL
```
http://127.0.0.1:8000/api/transactions
```

## Authentication
All endpoints require a Bearer token in the Authorization header:
```
Authorization: Bearer <your_access_token>
```

## Core Transaction Endpoints

### 1. Process Deposit
**POST** `/deposit`

Process a deposit transaction to an account.

**Request Body:**
```json
{
  "acc_id": "ACC123456789",
  "amount": 1000.50,
  "description": "Salary deposit",
  "reference_no": "REF12345" // Optional
}
```

**Response:**
```json
{
  "success": true,
  "message": "Deposit of $1000.50 processed successfully",
  "transaction_id": "TXN123ABC456DEF",
  "new_balance": 5000.50,
  "timestamp": "2025-09-17T10:30:00Z"
}
```

### 2. Process Withdrawal
**POST** `/withdraw`

Process a withdrawal transaction from an account.

**Request Body:**
```json
{
  "acc_id": "ACC123456789",
  "amount": 500.00,
  "description": "ATM withdrawal",
  "reference_no": "REF67890" // Optional
}
```

**Response:**
```json
{
  "success": true,
  "message": "Withdrawal of $500.00 processed successfully",
  "transaction_id": "TXN789GHI012JKL",
  "new_balance": 4500.50,
  "timestamp": "2025-09-17T11:00:00Z"
}
```

## Transaction History Endpoints

### 3. Get Account Transactions
**GET** `/account/{acc_id}`

Get paginated transaction history for a specific account.

**Parameters:**
- `acc_id` (path): Account ID
- `page` (query, optional): Page number (default: 1)
- `per_page` (query, optional): Records per page (default: 50, max: 100)

**Response:**
```json
{
  "acc_id": "ACC123456789",
  "transactions": [
    {
      "transaction_id": "TXN123ABC456DEF",
      "amount": 1000.50,
      "acc_id": "ACC123456789",
      "type": "Deposit",
      "description": "Salary deposit",
      "reference_no": "REF12345",
      "created_at": "2025-09-17T10:30:00Z",
      "created_by": "USER123",
      "balance_after": 5000.50
    }
  ],
  "total_count": 150,
  "page": 1,
  "per_page": 50,
  "total_pages": 3,
  "current_balance": 5000.50
}
```

### 4. Get Transaction Details
**GET** `/transaction/{transaction_id}`

Get details of a specific transaction.

**Parameters:**
- `transaction_id` (path): Transaction ID

**Response:**
```json
{
  "transaction_id": "TXN123ABC456DEF",
  "amount": 1000.50,
  "acc_id": "ACC123456789",
  "type": "Deposit",
  "description": "Salary deposit",
  "reference_no": "REF12345",
  "created_at": "2025-09-17T10:30:00Z",
  "created_by": "USER123",
  "balance_after": 5000.50
}
```

## Reporting Endpoints

### 5. Get Transactions by Date Range
**POST** `/report/date-range`

Get transactions within a specific date range with optional filters.

**Request Body:**
```json
{
  "start_date": "2025-09-01",
  "end_date": "2025-09-17",
  "acc_id": "ACC123456789", // Optional
  "transaction_type": "Deposit" // Optional: "Deposit", "Withdrawal", "Interest", "banktransfer"
}
```

**Response:**
```json
{
  "transactions": [...],
  "total_count": 25,
  "date_range": {
    "start_date": "2025-09-01",
    "end_date": "2025-09-17"
  },
  "summary": {
    "total_transactions": 25,
    "total_deposits": 15000.00,
    "total_withdrawals": 8000.00,
    "total_transfers": 2000.00,
    "net_change": 7000.00,
    "average_transaction": 600.00
  }
}
```

### 6. Get Branch Transaction Report
**POST** `/report/branch/{branch_id}`

Get comprehensive transaction report for a specific branch.

**Parameters:**
- `branch_id` (path): Branch ID
- `start_date` (query): Start date (YYYY-MM-DD)
- `end_date` (query): End date (YYYY-MM-DD)
- `transaction_type` (query, optional): Transaction type filter

**Response:**
```json
{
  "branch_id": "BR001",
  "branch_name": "Main Branch",
  "total_deposits": 50000.00,
  "total_withdrawals": 30000.00,
  "total_transfers": 10000.00,
  "transaction_count": 125,
  "date_range": {
    "start_date": "2025-09-01",
    "end_date": "2025-09-17"
  },
  "top_accounts": [
    {
      "acc_id": "ACC123456789",
      "acc_holder_name": "John Doe",
      "transaction_count": 15,
      "total_volume": 5000.00
    }
  ]
}
```

## Summary Endpoints

### 7. Get Account Transaction Summary
**POST** `/summary/{acc_id}`

Get aggregated transaction summary for an account.

**Parameters:**
- `acc_id` (path): Account ID
- `period` (query): Summary period ("daily", "weekly", "monthly", "yearly")
- `start_date` (query, optional): Start date filter
- `end_date` (query, optional): End date filter

**Response:**
```json
{
  "acc_id": "ACC123456789",
  "period": "monthly",
  "summaries": [
    {
      "year": 2025,
      "month": 9,
      "total_deposits": 15000.00,
      "total_withdrawals": 8000.00,
      "total_transfers": 2000.00,
      "transaction_count": 25,
      "net_change": 7000.00,
      "opening_balance": 10000.00,
      "closing_balance": 17000.00
    }
  ],
  "total_summary": {
    "total_deposits": 15000.00,
    "total_withdrawals": 8000.00,
    "total_transactions": 25,
    "net_change": 7000.00,
    "average_transaction": 600.00
  }
}
```

## Analytics Endpoints

### 8. Get Transaction Analytics
**GET** `/analytics/{acc_id}`

Get detailed analytics and patterns for an account.

**Parameters:**
- `acc_id` (path): Account ID
- `days` (query, optional): Number of days to analyze (default: 30, max: 365)

**Response:**
```json
{
  "acc_id": "ACC123456789",
  "total_transactions": 50,
  "avg_transaction_amount": 750.50,
  "largest_deposit": {
    "amount": 5000.00,
    "count": 8
  },
  "largest_withdrawal": {
    "amount": 2000.00,
    "count": 12
  },
  "most_active_day": {
    "date": "2025-09-15",
    "transaction_count": 5
  },
  "transaction_frequency": {
    "deposits": 20,
    "withdrawals": 30
  }
}
```

## Utility Endpoints

### 9. Get Account Balance
**GET** `/account/{acc_id}/balance`

Get current balance for an account.

**Parameters:**
- `acc_id` (path): Account ID

**Response:**
```json
{
  "acc_id": "ACC123456789",
  "balance": 5000.50,
  "message": "Balance retrieved successfully",
  "timestamp": "2025-09-17T12:00:00Z"
}
```

### 10. Get All Transactions Report
**GET** `/report/all-transactions`

Get comprehensive transaction report with advanced filtering (Admin endpoint).

**Parameters:**
- `page` (query): Page number (default: 1)
- `per_page` (query): Records per page (default: 100, max: 500)
- `acc_id` (query, optional): Account ID filter
- `transaction_type` (query, optional): Transaction type filter
- `start_date` (query, optional): Start date filter
- `end_date` (query, optional): End date filter

**Response:**
```json
{
  "transactions": [...],
  "total_count": 500,
  "page": 1,
  "per_page": 100,
  "summary": {...},
  "filters": {
    "acc_id": null,
    "transaction_type": "Deposit",
    "start_date": "2025-09-01",
    "end_date": "2025-09-17"
  }
}
```

### 11. Health Check
**GET** `/health`

Service health check endpoint.

**Response:**
```json
{
  "service": "Transaction Management",
  "status": "healthy",
  "version": "1.0.0",
  "endpoints": [
    "/deposit",
    "/withdraw",
    "/account/{acc_id}",
    "/report/date-range",
    "/report/branch/{branch_id}",
    "/summary/{acc_id}",
    "/analytics/{acc_id}"
  ]
}
```

## Error Responses

All endpoints return appropriate HTTP status codes and error messages:

### 400 Bad Request
```json
{
  "detail": "Insufficient funds. Current balance: $100.00, Requested: $500.00"
}
```

### 401 Unauthorized
```json
{
  "detail": "Authentication required"
}
```

### 404 Not Found
```json
{
  "detail": "Account not found"
}
```

### 500 Internal Server Error
```json
{
  "detail": "Deposit processing failed: Database connection error"
}
```

## Transaction Types
- `Deposit`: Money deposited into account
- `Withdrawal`: Money withdrawn from account
- `Interest`: Interest credited to account
- `banktransfer`: Transfer between accounts

## SQL Functions Used
The API relies on the following PostgreSQL functions:
- `process_deposit_transaction()`: Handles deposit processing
- `process_withdrawal_transaction()`: Handles withdrawal processing
- `get_transaction_history_by_account()`: Retrieves account transaction history
- `get_transaction_history_by_date_range()`: Gets transactions by date range
- `get_branch_transaction_report()`: Generates branch reports
- `calculate_transaction_totals()`: Calculates transaction summaries
- `get_all_transactions_with_account_details()`: Gets all transactions with account info

## Testing

To test the endpoints:

1. Start the server: `uvicorn app.main:app --reload`
2. Visit the interactive API docs: `http://127.0.0.1:8000/docs`
3. Use the "Authorize" button to add your Bearer token
4. Test individual endpoints using the interactive interface

## Notes
- All monetary amounts are in decimal format with 2 decimal places
- Timestamps are in ISO 8601 format
- All endpoints require valid authentication
- Rate limiting may apply to prevent abuse
- Large result sets are paginated for performance