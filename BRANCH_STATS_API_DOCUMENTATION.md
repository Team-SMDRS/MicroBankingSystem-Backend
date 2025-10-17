# Branch Statistics API Documentation

## Overview
This API provides comprehensive statistics for branch accounts including joint accounts, fixed deposits, and savings accounts.

## Endpoints

### 1. Get All Branches List
**GET** `/api/branches/list`

Returns a list of all branches for dropdown selection.

**Response:**
```json
{
  "branches": [
    {
      "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
      "branch_name": "Main Branch",
      "branch_code": "BR001",
      "city": "Colombo"
    },
    {
      "branch_id": "b5c3a0d2-1234-5678-9abc-def012345678",
      "branch_name": "Mount Lavinia Branch",
      "branch_code": "BR002",
      "city": "Mount Lavinia"
    }
  ],
  "total_count": 2
}
```

### 2. Get Branch Account Statistics
**GET** `/api/branches/{branch_id}/statistics`

Returns comprehensive statistics for a specific branch.

**Parameters:**
- `branch_id` (path parameter): UUID of the branch

**Response:**
```json
{
  "branch_id": "3dd6870c-e6f2-414d-9973-309ba00ce115",
  "branch_name": "Main Branch",
  "branch_code": "BR001",
  "total_joint_accounts": 5,
  "joint_accounts_balance": 250000.00,
  "total_fixed_deposits": 10,
  "fixed_deposits_amount": 1500000.00,
  "total_savings_accounts": 25,
  "savings_accounts_balance": 750000.00
}
```

## Statistics Details

### Joint Accounts
- **total_joint_accounts**: Count of accounts with more than one owner
- **joint_accounts_balance**: Combined balance of all joint accounts

### Fixed Deposits
- **total_fixed_deposits**: Count of fixed deposit accounts in the branch
- **fixed_deposits_amount**: Total amount invested in fixed deposits

### Savings/Current Accounts
- **total_savings_accounts**: Count of regular accounts (excluding joint accounts to avoid double counting)
- **savings_accounts_balance**: Combined balance of all savings accounts

## Authentication
Both endpoints require authentication. Include the JWT token in the Authorization header:
```
Authorization: Bearer <your-token>
```

## Usage Example

### Frontend Integration (React/TypeScript)

```typescript
// 1. Fetch branches for dropdown
const fetchBranches = async () => {
  const response = await fetch('http://localhost:8000/api/branches/list', {
    headers: {
      'Authorization': `Bearer ${token}`
    }
  });
  const data = await response.json();
  return data.branches;
};

// 2. Fetch statistics for selected branch
const fetchBranchStats = async (branchId: string) => {
  const response = await fetch(
    `http://localhost:8000/api/branches/${branchId}/statistics`,
    {
      headers: {
        'Authorization': `Bearer ${token}`
      }
    }
  );
  return await response.json();
};
```

## Files Created

### Backend Structure
```
app/
├── schemas/
│   └── branch_stats_schema.py       # Pydantic models
├── repositories/
│   └── branch_stats_repo.py         # Database queries
├── services/
│   └── branch_stats_service.py      # Business logic
└── api/
    └── branch_stats_routes.py       # API endpoints
```

### Database Query Logic
The repository uses PostgreSQL CTEs (Common Table Expressions) to:
1. Calculate joint accounts (accounts with multiple owners)
2. Calculate fixed deposits linked to the branch
3. Calculate savings accounts (excluding joint accounts)
4. Combine all statistics in a single query

## Error Handling
- **404**: Branch not found
- **500**: Internal server error with detailed message
- **401**: Unauthorized (missing or invalid token)
