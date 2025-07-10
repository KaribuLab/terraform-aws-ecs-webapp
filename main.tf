resource "aws_ecs_task_definition" "webapp" {
  family                   = var.service_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = var.task_policy_json != null ? aws_iam_role.task[0].arn : null

  container_definitions = jsonencode([
    {
      name      = var.service_name,
      image     = "${var.docker_image}:${var.image_tag}",
      essential = true,
      portMappings = [
        {
          containerPort = var.container_port,
          protocol      = "tcp"
        }
      ],
      environment = var.environment_variables,
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = var.cloudwatch_log_group_name,
          "awslogs-region"        = data.aws_region.current.name,
          "awslogs-stream-prefix" = var.service_name
        }
      }
    }
  ])

  tags = var.common_tags
}

resource "aws_service_discovery_service" "webapp" {
  count = var.service_discovery != null ? 1 : 0
  name  = var.service_discovery.dns.name

  dns_config {
    namespace_id = var.service_discovery.namespace_id

    dns_records {
      type = var.service_discovery.dns.type
      ttl  = var.service_discovery.dns.ttl
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}


resource "aws_ecs_service" "webapp" {
  name            = var.service_name
  cluster         = var.cluster_name
  task_definition = aws_ecs_task_definition.webapp.arn
  desired_count   = var.autoscaling_config.min_capacity
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }

  dynamic "service_registries" {
    for_each = aws_service_discovery_service.webapp
    content {
      registry_arn = each.value.arn
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.webapp.arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_maximum_percent         = var.deployment_config.maximum_percent
  deployment_minimum_healthy_percent = var.deployment_config.minimum_healthy_percent
  force_new_deployment               = var.force_new_deployment

  deployment_circuit_breaker {
    enable   = var.enable_deployment_circuit_breaker
    rollback = var.enable_deployment_circuit_breaker
  }

  depends_on = [aws_lb_listener_rule.webapp]

  tags = var.common_tags
}

resource "aws_lb_target_group" "webapp" {
  name                 = "${var.service_name}-tg"
  port                 = var.container_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = var.target_group_deregistration_delay

  health_check {
    path                = var.health_check.path
    interval            = var.health_check.interval
    timeout             = var.health_check.timeout
    healthy_threshold   = var.health_check.healthy_threshold
    unhealthy_threshold = var.health_check.unhealthy_threshold
    matcher             = var.health_check.matcher
  }

  tags = var.common_tags
}

resource "aws_lb_listener_rule" "webapp" {
  for_each = {
    for rule in var.listener_rules : "rule-${rule.priority}" => rule
  }

  listener_arn = var.alb_listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webapp.arn
  }

  condition {
    path_pattern {
      values = each.value.path_patterns != null ? each.value.path_patterns : []
    }
    host_header {
      values = each.value.host_headers != null ? each.value.host_headers : []
    }
  }

  tags = var.common_tags
}

resource "aws_iam_role" "execution" {
  name = "${var.service_name}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# Adjuntar política de ejecución de ECS para permisos para extraer imágenes y enviar logs
resource "aws_iam_role_policy_attachment" "execution_policy" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Rol de tarea específico que se crea solo si se proporciona una política JSON
resource "aws_iam_role" "task" {
  count = var.task_policy_json != null ? 1 : 0

  name = "${var.service_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# Política en línea que se crea solo si se proporciona una política JSON
resource "aws_iam_role_policy" "task_policy" {
  count = var.task_policy_json != null ? 1 : 0

  name   = "${var.service_name}-policy"
  role   = aws_iam_role.task[0].id
  policy = var.task_policy_json
}

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.autoscaling_config.max_capacity
  min_capacity       = var.autoscaling_config.min_capacity
  resource_id        = "service/${var.cluster_name}/${var.service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = var.common_tags
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.autoscaling_config.cpu != null ? 1 : 0
  name               = "cpu-scaling-policy-${var.service_name}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = var.autoscaling_config.cpu.target_value
    scale_in_cooldown  = var.autoscaling_config.cpu.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_config.cpu.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "memory" {
  count              = var.autoscaling_config.memory != null ? 1 : 0
  name               = "memory-scaling-policy-${var.service_name}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.autoscaling_config.memory.target_value
    scale_in_cooldown  = var.autoscaling_config.memory.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_config.memory.scale_out_cooldown
  }
}


# Get current AWS region
data "aws_region" "current" {}

# Security Group for ECS Service
resource "aws_security_group" "ecs_service" {
  name        = "${var.service_name}-sg"
  description = "Security group for ECS service ${var.service_name}"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(var.common_tags, {
    Name = "${var.service_name}-sg"
  })
}

# Security Group Rules for ECS Service
resource "aws_security_group_rule" "webapp" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = var.alb_security_group_id
  security_group_id        = aws_security_group.ecs_service.id
  description              = "Allow traffic from ALB security group (${var.alb_security_group_id}) to container port ${var.container_port}"
}
