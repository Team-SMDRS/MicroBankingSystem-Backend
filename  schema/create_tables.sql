CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- provides gen_random_uuid()

-- Users (agents/employees)
CREATE TABLE users (
  user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nic VARCHAR(12) UNIQUE,
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  address VARCHAR(100),
  phone_number VARCHAR(15),
  dob DATE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);


CREATE TABLE user_login (
  login_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE NOT NULL,   -- one-to-one with users
  username VARCHAR(50) UNIQUE NOT NULL,
  password TEXT NOT NULL,         -- store hash as TEXT
  password_last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id),
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
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);

-- FD Plan
CREATE TABLE fd_plan (
  fd_plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  duration INT,
  interest_rate NUMERIC(5,2),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);

-- Savings Plan
CREATE TABLE savings_plan (
  savings_plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_name VARCHAR(100),
  interest_rate NUMERIC(5,2),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);


-- Account
CREATE TABLE account (
  acc_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_no VARCHAR(20) UNIQUE,
  branch_id UUID REFERENCES branch(branch_id),
  savings_plan_id UUID REFERENCES savings_plan(savings_plan_id),
  balance NUMERIC(24,12),
  opened_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);

-- Fixed Deposit
CREATE TABLE fixed_deposit (
  fd_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance NUMERIC(18,12),
  acc_id UUID REFERENCES account(acc_id),
  opened_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  maturity_date TIMESTAMP,
  fd_plan_id UUID REFERENCES fd_plan(fd_plan_id),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);




-- Transactions
CREATE TYPE transaction_type AS ENUM ('Deposit', 'Withdrawal', 'Interest', 'BankTransfer');

CREATE TABLE transactions (
  transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  amount NUMERIC(12,2) NOT NULL,
  acc_id UUID REFERENCES account(acc_id),
  type transaction_type NOT NULL,
  description TEXT,
  reference_no VARCHAR(50),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id)
);
-- roles
CREATE TABLE role (
  role_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_name VARCHAR(50) UNIQUE NOT NULL
);


CREATE TABLE users_role (
  user_id UUID REFERENCES users(user_id),
  role_id UUID REFERENCES role(role_id),
  PRIMARY KEY (user_id, role_id)
);

-- Customers
CREATE TABLE customer (
  customer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name VARCHAR(150) NOT NULL,
  address VARCHAR(255),
  phone_number VARCHAR(15),
  nic VARCHAR(12) UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id)
);


-- Customer login 
CREATE TABLE customer_login (
  login_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID UNIQUE NOT NULL,   -- one-to-one with customers
  username VARCHAR(50) UNIQUE NOT NULL,
  password TEXT NOT NULL,         -- store hash as TEXT
  password_last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES users(user_id),
  updated_by UUID REFERENCES users(user_id),
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

-- Audit/History table for tracking all changes
CREATE TYPE audit_action AS ENUM ('INSERT', 'UPDATE', 'DELETE');

CREATE TABLE audit_log (
  audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name VARCHAR(50) NOT NULL,
  record_id UUID NOT NULL,
  action audit_action NOT NULL,
  old_values JSONB,
  changed_fields TEXT[],
  user_id UUID REFERENCES users(user_id),
  timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);





-- Refresh tokens for users (agents/employees)
CREATE TABLE user_refresh_tokens (
  token_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  token_hash TEXT NOT NULL,        -- store hashed refresh token
  expires_at TIMESTAMP NOT NULL,
  is_revoked BOOLEAN DEFAULT FALSE,
  device_info TEXT,               -- optional: store device/browser info
  ip_address INET,                -- optional: store IP address
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  revoked_at TIMESTAMP,
  revoked_by UUID REFERENCES users(user_id),
  FOREIGN KEY (user_id) REFERENCES user_login(user_id) ON DELETE CASCADE
);


-- Function to clean up expired user refresh tokens
CREATE OR REPLACE FUNCTION cleanup_expired_user_refresh_tokens()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM user_refresh_tokens WHERE expires_at < CURRENT_TIMESTAMP;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;


-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for automatic updated_at timestamp updates
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_user_login_updated_at BEFORE UPDATE ON user_login FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_branch_updated_at BEFORE UPDATE ON branch FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_fd_plan_updated_at BEFORE UPDATE ON fd_plan FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_savings_plan_updated_at BEFORE UPDATE ON savings_plan FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_account_updated_at BEFORE UPDATE ON account FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_fixed_deposit_updated_at BEFORE UPDATE ON fixed_deposit FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_role_updated_at BEFORE UPDATE ON role FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_customer_updated_at BEFORE UPDATE ON customer FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_customer_login_updated_at BEFORE UPDATE ON customer_login FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Useful indexes for performance
CREATE INDEX idx_users_nic ON users(nic);
CREATE INDEX idx_users_created_at ON users(created_at);
CREATE INDEX idx_customer_nic ON customer(nic);
CREATE INDEX idx_customer_created_at ON customer(created_at);
CREATE INDEX idx_account_account_no ON account(account_no);
CREATE INDEX idx_account_branch_id ON account(branch_id);
CREATE INDEX idx_transactions_acc_id ON transactions(acc_id);
CREATE INDEX idx_transactions_created_at ON transactions(created_at);
CREATE INDEX idx_transactions_type ON transactions(type);
CREATE INDEX idx_audit_log_table_record ON audit_log(table_name, record_id);
CREATE INDEX idx_audit_log_timestamp ON audit_log(timestamp);
CREATE INDEX idx_audit_log_user_id ON audit_log(user_id);
CREATE INDEX idx_login_user_id ON login(user_id);
CREATE INDEX idx_login_time ON login(login_time);







-- Add refresh token triggers and indexes after the existing triggers
CREATE TRIGGER update_user_refresh_tokens_updated_at BEFORE UPDATE ON user_refresh_tokens FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Add refresh token indexes after the existing indexes
CREATE INDEX idx_user_refresh_tokens_user_id ON user_refresh_tokens(user_id);
CREATE INDEX idx_user_refresh_tokens_hash ON user_refresh_tokens(token_hash);
CREATE INDEX idx_user_refresh_tokens_expires_at ON user_refresh_tokens(expires_at);
CREATE INDEX idx_user_refresh_tokens_revoked ON user_refresh_tokens(is_revoked);


-- Function to create a new user with login credentials
CREATE OR REPLACE FUNCTION create_user(
    p_nic VARCHAR(12),
    p_first_name VARCHAR(100),
    p_last_name VARCHAR(100),
    p_address VARCHAR(100),
    p_phone_number VARCHAR(15),
    p_dob DATE,
    p_username VARCHAR(50),
    p_password_hash TEXT,
    p_created_by UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_user_id UUID;
    new_login_id UUID;
BEGIN
    -- Insert into users table
    INSERT INTO users (
        nic, first_name, last_name, address, phone_number, dob, 
        created_by, updated_by
    ) VALUES (
        p_nic, p_first_name, p_last_name, p_address, p_phone_number, p_dob,
        p_created_by, p_created_by
    ) RETURNING user_id INTO new_user_id;

    -- Insert into user_login table
    INSERT INTO user_login (
        user_id, username, password, created_by, updated_by
    ) VALUES (
        new_user_id, p_username, p_password_hash, p_created_by, p_created_by
    ) RETURNING login_id INTO new_login_id;

    -- Return the new user_id
    RETURN new_user_id;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Rollback will happen automatically
        RAISE;
END;
$$ LANGUAGE plpgsql;

-- Function to create a user without created_by (for initial admin user)
CREATE OR REPLACE FUNCTION create_initial_user(
    p_nic VARCHAR(12),
    p_first_name VARCHAR(100),
    p_last_name VARCHAR(100),
    p_address VARCHAR(100),
    p_phone_number VARCHAR(15),
    p_dob DATE,
    p_username VARCHAR(50),
    p_password_hash TEXT
) RETURNS UUID AS $$
DECLARE
    new_user_id UUID;
BEGIN
    -- Insert into users table (without created_by for first admin)
    INSERT INTO users (
        nic, first_name, last_name, address, phone_number, dob
    ) VALUES (
        p_nic, p_first_name, p_last_name, p_address, p_phone_number, p_dob
    ) RETURNING user_id INTO new_user_id;

    -- Insert into user_login table
    INSERT INTO user_login (
        user_id, username, password
    ) VALUES (
        new_user_id, p_username, p_password_hash
    );

    -- Return the new user_id
    RETURN new_user_id;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE;
END;
$$ LANGUAGE plpgsql;

