# Branch service - Business logic for branch operations

from fastapi import HTTPException


class BranchService:
    def __init__(self, repo):
        self.repo = repo

    def get_all_branches(self):
        """Get all branches from the database"""
        try:
            branches = self.repo.get_all_branches()
            return branches
        except Exception as e:
            raise HTTPException(
                status_code=500, detail="Failed to retrieve branches")

    def get_branch_by_id(self, branch_id):
        """Get a branch by its ID"""
        try:
            branch = self.repo.get_branch_by_id(branch_id)
            if not branch:
                raise HTTPException(status_code=404, detail="Branch not found")
            return branch
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(
                status_code=500, detail="Failed to retrieve branch by ID")

    def get_branch_by_name(self, branch_name):
        """Get a branch by its name"""
        try:
            branch = self.repo.get_branch_by_name(branch_name)
            if not branch:
                raise HTTPException(status_code=404, detail="Branch not found")
            return branch
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(
                status_code=500, detail="Failed to retrieve branch by name")

    def update_branch(self, branch_id, update_data, current_user_id):
        """Update branch details by branch ID"""
        try:
            # Basic validation
            if 'name' in update_data and update_data['name'] is not None:
                if not update_data['name'].strip():
                    raise HTTPException(
                        status_code=400, detail="Branch name cannot be empty")
            
            if 'address' in update_data and update_data['address'] is not None:
                if not update_data['address'].strip():
                    raise HTTPException(
                        status_code=400, detail="Branch address cannot be empty")
            
            # Call repository which uses database function
            updated_branch = self.repo.update_branch(branch_id, update_data, current_user_id)
            
            if updated_branch is None:
                raise HTTPException(
                    status_code=400, detail="No valid fields to update")
            
            return updated_branch
            
        except HTTPException:
            raise
        except Exception as e:
            error_message = str(e)
            if "not found" in error_message:
                raise HTTPException(status_code=404, detail="Branch not found")
            elif "already exists" in error_message:
                raise HTTPException(status_code=400, detail=error_message)
            elif "No valid fields to update" in error_message:
                raise HTTPException(status_code=400, detail=error_message)
            else:
                raise HTTPException(
                    status_code=500, detail=f"Failed to update branch: {error_message}")

    def create_branch(self, branch_data, current_user_id):
        """Create a new branch"""
        try:
            # Basic validation (database function will handle detailed validation)
            if not branch_data.name or not branch_data.name.strip():
                raise HTTPException(
                    status_code=400, detail="Branch name is required")
            
            if not branch_data.address or not branch_data.address.strip():
                raise HTTPException(
                    status_code=400, detail="Branch address is required")
            
            # Call repository which uses database function
            created_branch = self.repo.create_branch(branch_data, current_user_id)
            return created_branch
            
        except HTTPException:
            raise
        except Exception as e:
            # Handle specific database errors
            error_message = str(e)
            if "already exists" in error_message:
                raise HTTPException(status_code=400, detail=error_message)
            elif "cannot be empty" in error_message:
                raise HTTPException(status_code=400, detail=error_message)
            else:
                raise HTTPException(
                    status_code=500, detail=f"Failed to create branch: {error_message}")
