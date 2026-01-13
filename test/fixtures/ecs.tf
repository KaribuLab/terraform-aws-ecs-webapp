# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "terratest-fixtures-cluster"

  tags = {
    Name      = "terratest-fixtures-cluster"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/terratest-fixtures-service"
  retention_in_days = 7

  tags = {
    Name      = "terratest-fixtures-log-group"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# SSM Parameters for secrets
resource "aws_ssm_parameter" "test_secret" {
  name        = "/ecs/terratest-fixtures/TEST_SECRET"
  description = "Test secret for ECS service"
  type        = "SecureString"
  value       = "test-secret-value"
  overwrite   = true

  tags = {
    Name      = "terratest-fixtures-test-secret"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

resource "aws_ssm_parameter" "api_key" {
  name        = "/ecs/terratest-fixtures/API_KEY"
  description = "API key secret for ECS service"
  type        = "SecureString"
  value       = "test-api-key-12345"
  overwrite   = true

  tags = {
    Name      = "terratest-fixtures-api-key"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}
