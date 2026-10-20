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

variable "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Target Group will be created"
  type        = string
}

variable "alb_load_balancer_arn" {
  description = "ARN of the ALB load balancer (HTTP or HTTPS). Required if using ALB."
  type        = string
  default     = null
}

variable "alb_listener_arn" {
  description = "ARN of the ALB listener (HTTP or HTTPS). Required if using ALB."
  type        = string
  default     = null
}

variable "alb_security_group_id" {
  description = "ID del security group del Application Load Balancer. Required if using ALB."
  type        = string
  default     = null
}

variable "service_discovery" {
  description = "ID of the Service Discovery namespace"
  type = object({
    namespace_id = string
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

  validation {
    condition = alltrue([
      for secret in var.secret_variables :
      can(regex("^arn:aws:(secretsmanager|ssm):", secret.valueFrom))
    ])
    error_message = "All secret_variables.valueFrom must be valid ARNs starting with 'arn:aws:secretsmanager:' or 'arn:aws:ssm:'"
  }
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
  description = "List of listener rules. Required if using ALB."
  type = list(object({
    priority      = number
    path_patterns = optional(list(string))
    host_headers  = optional(list(string))
  }))
  default = []
}

variable "desired_count" {
  description = "Desired number of ECS tasks when the service is created and autoscaling_config is null. When autoscaling is enabled, min_capacity is used for the initial count. Later applies do not change the running count."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count must be greater than or equal to 0"
  }
}

variable "autoscaling_config" {
  description = <<-EOT
    Auto scaling configuration. Set to null to skip Application Auto Scaling resources.
    When null, the service uses desired_count and does not create autoscaling target or policies.

    When min_capacity = 0 and an ALB is configured, the module creates the wake Lambda,
    its target group, and the CloudWatch alarms. The caller does not create that Lambda.
    CPU and memory policies still cannot scale out from 0; the Lambda performs 0 -> 1.
    alb_request_count scales between 1 and max_capacity. It does not wake a service with no targets.

    idle_minutes is how long the ECS target group can stay without requests before the Lambda
    sets desired count to 0 and points the listener rule at itself. The ALB idle timeout is
    configured on the load balancer, outside this module, and should cover the task cold start.
  EOT
  type = object({
    min_capacity = number
    max_capacity = number
    idle_minutes = optional(number, 15)
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
  default = null

  validation {
    condition     = var.autoscaling_config == null || var.autoscaling_config.min_capacity >= 0
    error_message = "min_capacity must be greater than or equal to 0"
  }
  validation {
    condition     = var.autoscaling_config == null || var.autoscaling_config.max_capacity >= var.autoscaling_config.min_capacity
    error_message = "max_capacity must be greater than or equal to min_capacity"
  }
  validation {
    condition     = var.autoscaling_config == null || var.autoscaling_config.alb_request_count != null || var.autoscaling_config.memory != null || var.autoscaling_config.cpu != null
    error_message = "At least one of alb_request_count, memory, or cpu must be provided"
  }
  validation {
    condition     = var.autoscaling_config == null || var.autoscaling_config.min_capacity > 0 || var.autoscaling_config.alb_request_count != null || var.autoscaling_config.cpu != null || var.autoscaling_config.memory != null
    error_message = "When min_capacity = 0, at least one autoscaling policy (cpu, memory, or alb_request_count) must be provided."
  }
  validation {
    condition     = var.autoscaling_config == null || coalesce(var.autoscaling_config.idle_minutes, 15) >= 1
    error_message = "idle_minutes must be greater than or equal to 1"
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
}

variable "image_tag" {
  description = "Image tag"
  type        = string
  default     = "latest"
}

variable "container_command" {
  description = "Command to override the default CMD from the Dockerfile. If null, uses the default CMD from the image."
  type        = list(string)
  default     = null
}


