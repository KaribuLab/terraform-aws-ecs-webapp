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
