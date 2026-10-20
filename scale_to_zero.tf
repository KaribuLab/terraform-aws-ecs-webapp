locals {
  scale_to_zero_enabled      = var.autoscaling_config != null && var.autoscaling_config.min_capacity == 0 && var.alb_load_balancer_arn != null
  scale_to_zero_idle_minutes = local.scale_to_zero_enabled ? coalesce(var.autoscaling_config.idle_minutes, 15) : 15

  wake_name            = trimsuffix(substr("${var.service_name}-wake", 0, 32), "-")
  wake_function_name   = substr("${var.service_name}-wake", 0, 64)
  idle_alarm_name      = substr("${var.service_name}-idle", 0, 255)
  no_tasks_alarm_name  = substr("${var.service_name}-no-tasks", 0, 255)
  alb_metric_dimension = var.alb_load_balancer_arn == null ? null : replace(var.alb_load_balancer_arn, "/.*:loadbalancer\\//", "")
  ecs_tg_metric_dimension = one([
    for arn in aws_lb_target_group.webapp[*].arn : "targetgroup/${one(aws_lb_target_group.webapp[*].name)}/${split("/", arn)[2]}"
  ])
  scalable_target_resource_id = "service/${var.cluster_name}/${var.service_name}"
}

resource "terraform_data" "scale_to_zero_mode" {
  input = local.scale_to_zero_enabled
}

data "archive_file" "scale_to_zero" {
  count = local.scale_to_zero_enabled ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/lambda/scale_to_zero.zip"

  source {
    content  = file("${path.module}/lambda/handler.mjs")
    filename = "handler.mjs"
  }

  source {
    content  = file("${path.module}/lambda/package.json")
    filename = "package.json"
  }
}

resource "aws_cloudwatch_log_group" "scale_to_zero" {
  count = local.scale_to_zero_enabled ? 1 : 0

  name              = "/aws/lambda/${local.wake_function_name}"
  retention_in_days = 14
  tags              = var.common_tags
}

resource "aws_iam_role" "scale_to_zero" {
  count = local.scale_to_zero_enabled ? 1 : 0

  name = substr("${var.service_name}-wake-role", 0, 64)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "scale_to_zero_logs" {
  count = local.scale_to_zero_enabled ? 1 : 0

  role       = aws_iam_role.scale_to_zero[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "scale_to_zero" {
  count = local.scale_to_zero_enabled ? 1 : 0

  name = "${local.wake_name}-policy"
  role = aws_iam_role.scale_to_zero[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = [
          "arn:aws:ecs:${data.aws_region.current.name}:*:service/${var.cluster_name}/${var.service_name}",
          "arn:aws:ecs:${data.aws_region.current.name}:*:cluster/${var.cluster_name}",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:ModifyRule"]
        Resource = [for rule in aws_lb_listener_rule.webapp : rule.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeTargetHealth"]
        Resource = one(aws_lb_target_group.webapp[*].arn)
      },
      {
        Effect   = "Allow"
        Action   = ["application-autoscaling:RegisterScalableTarget"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "application-autoscaling:service-namespace" = "ecs"
          }
        }
      },
    ]
  })
}

resource "aws_lambda_function" "scale_to_zero" {
  count = local.scale_to_zero_enabled ? 1 : 0

  function_name    = local.wake_function_name
  role             = aws_iam_role.scale_to_zero[0].arn
  filename         = data.archive_file.scale_to_zero[0].output_path
  source_code_hash = data.archive_file.scale_to_zero[0].output_base64sha256
  handler          = "handler.handler"
  runtime          = "nodejs22.x"
  timeout          = 180
  memory_size      = 128

  environment {
    variables = {
      CLUSTER_NAME            = var.cluster_name
      SERVICE_NAME            = var.service_name
      ECS_TARGET_GROUP_ARN    = aws_lb_target_group.webapp[0].arn
      LAMBDA_TARGET_GROUP_ARN = aws_lb_target_group.wake[0].arn
      LISTENER_RULE_ARNS      = join(",", [for rule in aws_lb_listener_rule.webapp : rule.arn])
      RESOURCE_ID             = local.scalable_target_resource_id
      MIN_CAPACITY            = tostring(var.autoscaling_config.min_capacity)
      MAX_CAPACITY            = tostring(var.autoscaling_config.max_capacity)
      IDLE_ALARM_NAME         = local.idle_alarm_name
      NO_TASKS_ALARM_NAME     = local.no_tasks_alarm_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.scale_to_zero,
    aws_iam_role_policy.scale_to_zero,
    aws_iam_role_policy_attachment.scale_to_zero_logs,
  ]

  tags = var.common_tags
}

resource "aws_lb_target_group" "wake" {
  count = local.scale_to_zero_enabled ? 1 : 0

  name        = local.wake_name
  target_type = "lambda"
  tags        = var.common_tags
}

resource "aws_lambda_permission" "wake_alb" {
  count = local.scale_to_zero_enabled ? 1 : 0

  statement_id  = "AllowExecutionFromALB"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scale_to_zero[0].function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.wake[0].arn
}

resource "aws_lb_target_group_attachment" "wake" {
  count = local.scale_to_zero_enabled ? 1 : 0

  target_group_arn = aws_lb_target_group.wake[0].arn
  target_id        = aws_lambda_function.scale_to_zero[0].arn
  depends_on       = [aws_lambda_permission.wake_alb]
}

resource "aws_cloudwatch_metric_alarm" "scale_to_zero_idle" {
  count = local.scale_to_zero_enabled ? 1 : 0

  alarm_name          = local.idle_alarm_name
  alarm_description   = "Sin requests al target group de ECS. Apaga el service y deja la regla del listener en la Lambda."
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = local.scale_to_zero_idle_minutes
  datapoints_to_alarm = local.scale_to_zero_idle_minutes
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_lambda_function.scale_to_zero[0].arn]

  dimensions = {
    LoadBalancer = local.alb_metric_dimension
    TargetGroup  = local.ecs_tg_metric_dimension
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "scale_to_zero_no_tasks" {
  count = local.scale_to_zero_enabled ? 1 : 0

  alarm_name          = local.no_tasks_alarm_name
  alarm_description   = "El service quedó sin tasks. Apunta la regla del listener a la Lambda para poder despertarlo."
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "RunningTaskCount"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_lambda_function.scale_to_zero[0].arn]

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "wake_idle_alarm" {
  count = local.scale_to_zero_enabled ? 1 : 0

  statement_id  = "AllowIdleAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scale_to_zero[0].function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.scale_to_zero_idle[0].arn
}

resource "aws_lambda_permission" "wake_no_tasks_alarm" {
  count = local.scale_to_zero_enabled ? 1 : 0

  statement_id  = "AllowNoTasksAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scale_to_zero[0].function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.scale_to_zero_no_tasks[0].arn
}
