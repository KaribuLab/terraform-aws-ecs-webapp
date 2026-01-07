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

variable "service_discovery" {
  description = "ID of the Service Discovery namespace"
  type = object({
    namespace_id   = string
    dns = object({
      name = string
      type = string
      ttl  = number
    })
  })
  default = null
}

variable "environment_variables" {
  description = "Environment variables to pass to the container"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "secret_variables" {
  description = "Secrets to pass to the container. Each secret must have 'name' and 'valueFrom' (ARN of SSM Parameter Store or Secrets Manager)"
  type = list(object({
    name      = string
    valueFrom = string
  }))
  default = []
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
    priority      = number
    path_patterns = optional(list(string))
    host_headers  = optional(list(string))
  }))
  default = [
    {
      priority      = 100
      path_patterns = ["/*"]
    }
  ]
  validation {
    condition     = var.listener_rules[0].path_patterns != null || var.listener_rules[0].host_headers != null
    error_message = "At least one of path_patterns or host_headers must be provided"
  }
}

variable "autoscaling_config" {
  description = <<-EOT
    Auto scaling configuration.
    
    IMPORTANT: When min_capacity = 0:
    - The service can scale to zero tasks, but this has implications:
      * The ALB Target Group will have no healthy targets, causing 503 errors for incoming requests
      * CPU/Memory metrics won't be available when there are 0 tasks, so autoscaling policies based on these metrics cannot automatically scale up from 0
      * You must provide alb_request_count to enable automatic scaling from 0 based on ALB request metrics
    - Consider using min_capacity = 1 for production workloads with ALB to ensure availability
    - All policies (CPU, Memory, and ALB) can coexist. AWS Application Auto Scaling will use the policy that requires the highest capacity.
  EOT
  type = object({
    min_capacity = number
    max_capacity = number
    memory = optional(object({
      target_value       = number
      scale_in_cooldown  = number
      scale_out_cooldown = number
    }))
    cpu = optional(object({
      target_value       = number
      scale_in_cooldown  = number
      scale_out_cooldown = number
    }))
    alb_request_count = optional(object({
      target_value       = number
      scale_in_cooldown  = number
      scale_out_cooldown = number
    }))
  })
  validation {
    condition     = var.autoscaling_config.min_capacity >= 0
    error_message = "min_capacity must be greater than or equal to 0"
  }
  validation {
    condition     = var.autoscaling_config.max_capacity >= var.autoscaling_config.min_capacity
    error_message = "max_capacity must be greater than or equal to min_capacity"
  }
  validation {
    condition     = var.autoscaling_config.alb_request_count != null || var.autoscaling_config.memory != null || var.autoscaling_config.cpu != null
    error_message = "At least one of alb_request_count, memory, or cpu must be provided"
  }
  validation {
    condition     = var.autoscaling_config.min_capacity > 0 || var.autoscaling_config.alb_request_count != null
    error_message = "When min_capacity = 0, alb_request_count must be provided to enable automatic scaling from 0"
  }
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

variable "image_tag" {
  description = "Image tag"
  type        = string
  default     = "latest"
}


