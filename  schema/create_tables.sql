CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- provides gen_random_uuid()

CREATE TABLE activity (
  activity_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  logs TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP
  
);


-- Users (agents/employees)
CREATE TABLE users (
  user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nic VARCHAR(12) UNIQUE,
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  address VARCHAR(100),
  phone_number VARCHAR(15),
  dob DATE,
  activity_id UUID REFERENCES activity(activity_id)
);


CREATE TABLE user_login (
  login_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE NOT NULL,   -- one-to-one with users
  username VARCHAR(50) UNIQUE NOT NULL,
  password TEXT NOT NULL,         -- store hash as TEXT
  password_last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);
-- Login activity log
CREATE TABLE login (
  log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,         -- ties back to user_login
  login_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES user_login(user_id) ON DELETE CASCADE
);

-- Branch
CREATE TABLE branch (
  branch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(25),
  address VARCHAR(300),
  activity_id UUID REFERENCES activity(activity_id)
);

-- FD Plan
CREATE TABLE fd_plan (
  fd_plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  duration INT,
  interest_rate NUMERIC(5,2),
  activity_id UUID REFERENCES activity(activity_id)
);



-- Savings Plan
CREATE TABLE savings_plan (
  savings_plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_name VARCHAR(100),
  interest_rate NUMERIC(5,2),
  activity_id UUID REFERENCES activity(activity_id)
);


-- Account
CREATE TABLE account (
  acc_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_no VARCHAR(20) UNIQUE,
  branch_id UUID REFERENCES branch(branch_id),
  savings_plan_id UUID REFERENCES savings_plan(savings_plan_id),
  balance NUMERIC(12,2),
  opened_date TIMESTAMP,
  activity_id UUID REFERENCES activity(activity_id)
);

-- Fixed Deposit
CREATE TABLE fixed_deposit (
  fd_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance NUMERIC(18,2),
  acc_id UUID REFERENCES account(acc_id),
  opened_date TIMESTAMP,
  fd_plan_id UUID REFERENCES fd_plan(fd_plan_id),
  activity_id UUID REFERENCES activity(activity_id)
);




-- Transactions
CREATE TYPE transaction_type AS ENUM ('Deposit', 'Withdrawal', 'Interest', 'BankTransfer');

CREATE TABLE transactions (
  transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  amount NUMERIC(18,2),
  acc_id UUID REFERENCES account(acc_id),
  activity_id UUID REFERENCES activity(activity_id),
  type transaction_type
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
  role_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_name role_type,
  activity_id UUID REFERENCES activity(activity_id)
);


CREATE TABLE users_role (
  user_id UUID REFERENCES users(user_id),
  role_id UUID REFERENCES role(role_id),
  PRIMARY KEY (user_id, role_id)
);

-- Customers
CREATE TABLE customer (
  customer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name VARCHAR(150),
  address VARCHAR(255),
  phone_number VARCHAR(15),
  nic VARCHAR (12) UNIQUE,
  activity_id UUID REFERENCES activity(activity_id)
);


--cusomer login 

CREATE TABLE customer_login (
  login_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID UNIQUE NOT NULL,   -- one-to-one with users
  username VARCHAR(50) UNIQUE NOT NULL,
  password TEXT NOT NULL,         -- store hash as TEXT
  password_last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (customer_id) REFERENCES customer(customer_id) ON DELETE CASCADE
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