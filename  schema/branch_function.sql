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






