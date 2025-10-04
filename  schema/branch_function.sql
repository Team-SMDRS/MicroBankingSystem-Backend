-- create new branch
CREATE OR REPLACE FUNCTION create_branch
(
    p_branch_id UUID,
    p_name TEXT,
    p_address TEXT,
    p_created_by UUID
)

RETURNS TABLE
(branch_id UUID, name TEXT, address TEXT) AS $$

DECLARE
    v_branch_id UUID;
    v_name TEXT;
    v_address TEXT;

BEGIN
    -- Insert branch
    INSERT INTO branch
        (
        branch_id, name, address, created_by, updated_by
        )
    VALUES
        (
            p_branch_id, p_name, p_address, p_created_by, p_created_by
    )
    RETURNING branch.branch_id, branch.name, branch.address INTO v_branch_id, v_name, v_address;

RETURN QUERY
SELECT v_branch_id, v_name, v_address;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Error: %', SQLERRM;
        RAISE;
END;
$$ LANGUAGE plpgsql;

-- update branch
CREATE OR REPLACE FUNCTION update_branch
(
    p_branch_id UUID,
    p_name TEXT,
    p_address TEXT,
    p_updated_by UUID
)

RETURNS TABLE
(branch_id UUID, name TEXT, address TEXT, created_at TIMESTAMP, updated_at TIMESTAMP, created_by UUID, updated_by UUID) AS $$

DECLARE
    v_branch_id UUID;
    v_name TEXT;
    v_address TEXT;
    v_created_at TIMESTAMP;
    v_updated_at TIMESTAMP;
    v_created_by UUID;
    v_updated_by UUID;

BEGIN
    -- Check if branch exists
    IF NOT EXISTS (SELECT 1 FROM branch WHERE branch.branch_id = p_branch_id) THEN
        RAISE EXCEPTION 'Branch not found';
    END IF;

    -- Update branch with only non-null values
    UPDATE branch 
    SET 
        name = COALESCE(p_name, branch.name),
        address = COALESCE(p_address, branch.address),
        updated_at = NOW(),
        updated_by = p_updated_by
    WHERE branch.branch_id = p_branch_id
    RETURNING branch.branch_id, branch.name, branch.address, branch.created_at, branch.updated_at, branch.created_by, branch.updated_by 
    INTO v_branch_id, v_name, v_address, v_created_at, v_updated_at, v_created_by, v_updated_by;

    -- Return the updated branch
    RETURN QUERY
    SELECT v_branch_id, v_name, v_address, v_created_at, v_updated_at, v_created_by, v_updated_by;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Error: %', SQLERRM;
        RAISE;
END;
$$ LANGUAGE plpgsql;






