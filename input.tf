variable "cluster_name" {
  description = "Name of the ECS Cluster"
  type        = string
}

variable "service_name" {
  description = "Name of the ECS service"
  type        = string
}

variable "docker_image" {
  description = "Docker image in ECR"
  type        = string
}

variable "container_port" {
  description = "Port exposed by the container"
  type        = number
}

variable "task_cpu" {
  description = "Amount of CPU for the ECS task (in CPU units)"
  type        = string
}

variable "task_memory" {
  description = "Amount of memory for the ECS task (in MiB)"
  type        = string
}

variable "subnet_ids" {
  description = "IDs of private subnets for ECS tasks. IMPORTANT: Must be private subnets as tasks are configured without public IPs (assign_public_ip = false) and need to access the internet through a NAT Gateway to download Docker images"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID where the Target Group will be created"
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN of the ALB listener (HTTP or HTTPS)"
  type        = string
}

variable "alb_security_group_id" {
  description = "ID del security group del Application Load Balancer"
  type        = string
}

variable "environment_variables" {
  description = "Environment variables to pass to the container"
  type        = list(object({
    name  = string
    value = string
  }))
  default     = []
}

variable "health_check" {
  description = "Target Group health check configuration"
  type = object({
    path                = string
    interval            = number
    timeout             = number
    healthy_threshold   = number
    unhealthy_threshold = number
    matcher             = string
  })
}

variable "listener_rules" {
  description = "List of listener rules"
  type = list(object({
    priority = number
    path_patterns = list(string)
  }))
  default = [
    {
      priority      = 100
      path_patterns = ["/*"]
    }
  ]
}

variable "autoscaling_config" {
  description = "Auto scaling configuration"
  type = object({
    min_capacity       = number
    max_capacity       = number
    target_value       = number
    scale_in_cooldown  = number
    scale_out_cooldown = number
  })
}

variable "common_tags" {
  description = "Common tags to be applied to all resources (required)"
  type        = map(string)
}

variable "task_policy_json" {
  description = "IAM Policy document in JSON format to attach to the ECS Task Role"
  type        = string
  default     = null
}

variable "target_group_deregistration_delay" {
  description = "Amount of time for Elastic Load Balancing to wait before changing the state of a deregistering target from draining to unused"
  type        = number
  default     = 300
}

variable "force_new_deployment" {
  description = "Force a new deployment of the service when set to true"
  type        = bool
  default     = true
}

variable "deployment_config" {
  description = "Configuration for the ECS service deployment"
  type = object({
    maximum_percent         = number
    minimum_healthy_percent = number
  })
}

variable "enable_deployment_circuit_breaker" {
  description = "Whether to enable the deployment circuit breaker with rollback"
  type        = bool
  default     = false
}

variable "cloudwatch_log_group_name" {
  description = "Full name of the CloudWatch Log Group to use (e.g. /ecs/service-name)"
  type        = string
  default     = null
} 