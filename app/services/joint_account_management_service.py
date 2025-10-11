	
from app.repositories.joint_account_management_repo import JointAccountManagementRepository

class JointAccountManagementService:

	def __init__(self, db_conn):
		self.repo = JointAccountManagementRepository(db_conn)

	def create_joint_account(self, account_data, nic1, nic2, created_by_user_id):
		return self.repo.create_joint_account(account_data, nic1, nic2, created_by_user_id)

	def create_joint_account_with_new_customers(self, customer1_data, customer2_data, account_data, created_by_user_id):
		return self.repo.create_joint_account_with_new_customers(customer1_data, customer2_data, account_data, created_by_user_id)

	def create_joint_account_with_existing_and_new_customer(self, existing_nic, new_customer_data, account_data, created_by_user_id):
		return self.repo.create_joint_account_with_existing_and_new_customer(existing_nic, new_customer_data, account_data, created_by_user_id)