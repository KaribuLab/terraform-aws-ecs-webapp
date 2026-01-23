# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "terratest-fixtures-alb-sg"
  description = "Security group for test ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "terratest-fixtures-alb-sg"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "terratest-fixtures-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = {
    Name      = "terratest-fixtures-alb"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Default Target Group (required for listener)
resource "aws_lb_target_group" "default" {
  name        = "terratest-fixtures-default-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  tags = {
    Name      = "terratest-fixtures-default-tg"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# HTTP Listener
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.default.arn
  }
}
