output "alb_target_group_arn" {
  description = "ARN of the Target Group connected to the ALB. Null if ALB is not configured."
  value       = var.alb_listener_arn != null ? aws_lb_target_group.webapp[0].arn : null
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.webapp.name
} 

output "ecs_task_definition_arn" {
  description = "ARN of the ECS task definition"
  value       = aws_ecs_task_definition.webapp.arn
} 

output "iam_execution_role_arn" {
  description = "ARN of the ECS execution role"
  value       = aws_iam_role.execution.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = var.cluster_name
}

output "service_name" {
  description = "Name of the ECS service"
  value       = var.service_name
} 

output "security_group_id" {
  description = "ID of the security group used for the ECS service"
  value       = aws_security_group.ecs_service.id
} 