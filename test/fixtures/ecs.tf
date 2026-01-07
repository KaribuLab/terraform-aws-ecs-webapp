# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.test_name}-cluster"

  tags = {
    Name = "${var.test_name}-cluster"
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.test_name}-service"
  retention_in_days = 7

  tags = {
    Name = "${var.test_name}-log-group"
  }
}

# SSM Parameters for secrets
resource "aws_ssm_parameter" "test_secret" {
  name        = "/ecs/${var.test_name}/TEST_SECRET"
  description = "Test secret for ECS service"
  type        = "SecureString"
  value       = "test-secret-value"

  tags = {
    Name = "${var.test_name}-test-secret"
  }
}

resource "aws_ssm_parameter" "api_key" {
  name        = "/ecs/${var.test_name}/API_KEY"
  description = "API key secret for ECS service"
  type        = "SecureString"
  value       = "test-api-key-12345"

  tags = {
    Name = "${var.test_name}-api-key"
  }
}
