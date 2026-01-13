# Bootstrap resources for Terraform state backend
# These resources are created BEFORE the backend is configured
# They should be created manually or via a separate bootstrap script

# Get AWS account ID
data "aws_caller_identity" "current" {}

# S3 Bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "terraform-ecs-webapp-test-${var.aws_region}-${data.aws_caller_identity.current.account_id}"

  # Force destroy allows Terraform to delete the bucket even if it contains objects
  # This is safe for test infrastructure and allows cleanup to succeed
  force_destroy = true

  tags = {
    Name        = "Terraform State for ECS WebApp Tests"
    Purpose     = "terraform-state"
    Environment = "test"
    ManagedBy   = "terratest"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets  = true
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-ecs-webapp-test-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Terraform State Lock Table for ECS WebApp Tests"
    Purpose     = "terraform-locks"
    Environment = "test"
    ManagedBy   = "terratest"
  }
}
