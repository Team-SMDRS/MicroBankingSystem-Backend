-- Add status column to account table (option 1: flexible status)
-- ENUM type for stricter control (recommended)
CREATE TYPE account_status AS ENUM ('active', 'frozen', 'closed');
ALTER TABLE account ADD COLUMN status account_status DEFAULT 'active';

-- If you want to use VARCHAR instead, comment the above and use:
-- ALTER TABLE account ADD COLUMN status VARCHAR(20) DEFAULT 'active';
