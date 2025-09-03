-- Activity log
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE activity (
  activity_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  logs TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);


-- Users (agents/employees)
CREATE TABLE users (
  user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nic VARCHAR(12),
  first_name VARCHAR(100),
  last_name VARCHAR(100),
  address VARCHAR(100),
  phone_number VARCHAR(15),
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Login info
CREATE TABLE login (
  login_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES users(user_id),
  username VARCHAR(50) UNIQUE,
  hashed_password VARCHAR(255),
  password_last_update TIMESTAMP,
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);


-- Branch
CREATE TABLE branch (
  branch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(25),
  address VARCHAR(300),
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);

-- FD Plan
CREATE TABLE fd_plan (
  fd_plan_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  duration INT,
  interest_rate NUMERIC(5,2),
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);



-- Savings Plan
CREATE TABLE savings_plan (
  savings_plan_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plan_name VARCHAR(100),
  interest_rate NUMERIC(5,2),
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);


-- Account
CREATE TABLE account (
  acc_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_no VARCHAR(20) UNIQUE,
  branch_id UUID REFERENCES branch(branch_id),
  savings_plan_id UUID REFERENCES savings_plan(savings_plan_id),
  balance NUMERIC(12,2),
  opened_date TIMESTAMP,
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);

-- Fixed Deposit
CREATE TABLE fixed_deposit (
  fd_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  balance NUMERIC(18,2),
  acc_id UUID REFERENCES account(acc_id),
  opened_date TIMESTAMP,
  fd_plan_id UUID REFERENCES fd_plan(fd_plan_id),
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);




-- Transactions
CREATE TYPE transaction_type AS ENUM ('Deposit', 'Withdrawal', 'Interest', 'BankTransfer');

CREATE TABLE transactions (
  transaction_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  amount NUMERIC(18,2),
  acc_id UUID REFERENCES account(acc_id),
  activity_id UUID REFERENCES activity(activity_id),
  type transaction_type,
  created_at TIMESTAMP DEFAULT NOW()
);
-- Roles
CREATE TYPE role_type AS ENUM (
  'admin',
  'branch_manager',
  'depositor',
  'withdrawer',
  'account_creator',
  'fd_creator',
  'plan_manager'

);


CREATE TABLE role (
  role_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  role_name role_type,
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW()
);


CREATE TABLE users_role (
  user_id UUID REFERENCES users(user_id),
  role_id UUID REFERENCES role(role_id),
  PRIMARY KEY (user_id, role_id)
);

-- Customers
CREATE TABLE customer (
  customer_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name VARCHAR(150),
  address VARCHAR(255),
  phone_number VARCHAR(15),
  nic VARCHAR (12) UNIQUE,
  activity_id UUID REFERENCES activity(activity_id),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Users-Branch mapping
CREATE TABLE users_branch (
  user_id UUID REFERENCES users(user_id),
  branch_id UUID REFERENCES branch(branch_id),
  PRIMARY KEY (user_id, branch_id)
);

-- Account owners (customer <-> account)
CREATE TABLE accounts_owner (
  acc_id UUID REFERENCES account(acc_id),
  customer_id UUID REFERENCES customer(customer_id),
  PRIMARY KEY (acc_id, customer_id)
);