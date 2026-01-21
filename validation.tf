# Cross-variable validations using preconditions
# These validations ensure consistent configuration when ALB is used

resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = var.alb_listener_arn == null || var.alb_security_group_id != null
      error_message = "alb_security_group_id must be provided when alb_listener_arn is provided"
    }

    precondition {
      condition     = var.alb_listener_arn == null || var.health_check != null
      error_message = "health_check must be provided when alb_listener_arn is provided"
    }

    precondition {
      condition     = var.alb_listener_arn == null || length(var.listener_rules) > 0
      error_message = "At least one listener_rule must be provided when alb_listener_arn is provided"
    }

    precondition {
      condition     = var.alb_listener_arn != null || var.service_discovery != null
      error_message = "Either alb_listener_arn or service_discovery must be provided for service access"
    }

    precondition {
      condition     = var.autoscaling_config.alb_request_count == null || var.alb_listener_arn != null
      error_message = "alb_request_count autoscaling cannot be used without ALB (alb_listener_arn)"
    }
  }
}
