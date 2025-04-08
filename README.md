# Terraform AWS ECS WebApp

This module creates an ECS Fargate service for deploying web applications with load balancing.

## Inputs

| Name                           | Type          | Description                                                  | Required |
| ------------------------------ | ------------- | ------------------------------------------------------------ | -------- |
| cluster_name                   | string        | Name of the ECS Cluster                                      | yes      |
| service_name                   | string        | Name of the ECS service                                      | yes      |
| docker_image                   | string        | Docker image in ECR                                          | yes      |
| container_port                 | number        | Port exposed by the container                                | yes      |
| task_cpu                       | string        | Amount of CPU for the ECS task (in CPU units)                | yes      |
| task_memory                    | string        | Amount of memory for the ECS task (in MiB)                   | yes      |
| subnet_ids                     | list(string)  | IDs of the private subnets for ECS tasks                     | yes      |
| security_group_ids             | list(string)  | Security Groups for the ECS service                          | yes      |
| vpc_id                         | string        | VPC ID where the Target Group will be created                | yes      |
| alb_listener_arn               | string        | ARN of the ALB listener (HTTP or HTTPS)                      | yes      |
| environment_variables          | list(object)  | [Environment variables](#environment-variables) to pass to the container | no |
| health_check                   | object        | [Health check configuration](#health-check)                  | yes      |
| listener_rules                 | list(object)  | [List of listener rules](#listener-rules)                    | no       |
| autoscaling_config             | object        | [Auto scaling configuration](#autoscaling-config)            | yes      |
| common_tags                    | map(string)   | Common tags to be applied to all resources                   | yes      |
| task_policy_json               | string        | IAM Policy document in JSON format for the task role         | no       |
| target_group_port              | number        | Port for the target group (if different from container port) | no       |
| target_group_deregistration_delay | number     | Time for ELB to wait before deregistering targets            | no       |
| force_new_deployment           | bool          | Force a new deployment of the service                        | no       |
| deployment_config              | object        | [Deployment configuration](#deployment-config)               | yes      |
| enable_deployment_circuit_breaker | bool       | Enable deployment circuit breaker with rollback              | no       |

### Environment Variables

| Name  | Type   | Description                    | Required |
| ----- | ------ | ------------------------------ | -------- |
| name  | string | Name of the environment variable | yes    |
| value | string | Value of the environment variable | yes   |

### Health Check

| Name                | Type    | Description                                    | Required |
| ------------------- | ------- | ---------------------------------------------- | -------- |
| path                | string  | Path for the health check                      | yes      |
| interval            | number  | Interval between health checks                 | yes      |
| timeout             | number  | Timeout for the health check                   | yes      |
| healthy_threshold   | number  | Threshold to consider the task as healthy      | yes      |
| unhealthy_threshold | number  | Threshold to consider the task as unhealthy    | yes      |
| matcher             | string  | HTTP codes considered as success               | yes      |

### Listener Rules

| Name          | Type         | Description                       | Required |
| ------------- | ------------ | --------------------------------- | -------- |
| priority      | number       | Rule priority                     | yes      |
| path_patterns | list(string) | Path patterns for the rule        | yes      |

### Autoscaling Config

| Name              | Type   | Description                                        | Required |
| ----------------- | ------ | -------------------------------------------------- | -------- |
| min_capacity      | number | Minimum task capacity                              | yes      |
| max_capacity      | number | Maximum task capacity                              | yes      |
| target_value      | number | Target CPU utilization value for scaling           | yes      |
| scale_in_cooldown  | number | Cool-down time for scaling in (seconds)           | yes      |
| scale_out_cooldown | number | Cool-down time for scaling out (seconds)          | yes      |

### Deployment Config

| Name                    | Type   | Description                                      | Required |
| ----------------------- | ------ | ------------------------------------------------ | -------- |
| maximum_percent         | number | Maximum percentage of tasks during deployment    | yes      |
| minimum_healthy_percent | number | Minimum percentage of healthy tasks during deployment | yes |

## Outputs

| Name                    | Type   | Description                                 |
| ----------------------- | ------ | ------------------------------------------- |
| alb_target_group_arn    | string | ARN of the Target Group connected to the ALB|
| ecs_service_name        | string | Name of the ECS service                     |
| ecs_task_definition_arn | string | ARN of the ECS task definition              |
| iam_execution_role_arn  | string | ARN of the ECS execution role               |
| cluster_name            | string | Name of the ECS cluster                     |
| service_name            | string | Name of the ECS service                     |
| security_group_id       | string | ID of the security group created for the ECS service (if created) |

## Usage Example

```hcl
module "webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  cluster_name       = "my-cluster"
  service_name       = "app-frontend"
  docker_image       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/frontend:latest"
  container_port     = 3000
  task_cpu           = "256"
  task_memory        = "512"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.ecs_tasks.id]
  alb_listener_arn   = module.alb.http_listener_arn
  
  target_group_port  = 80
  
  environment_variables = [
    {
      name  = "NODE_ENV"
      value = "production"
    },
    {
      name  = "API_URL"
      value = "https://api.example.com"
    }
  ]

  health_check = {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

  autoscaling_config = {
    min_capacity       = 1
    max_capacity       = 4
    target_value       = 50
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }

  deployment_config = {
    maximum_percent         = 200
    minimum_healthy_percent = 100
  }

  task_policy_json = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          "arn:aws:s3:::my-bucket",
          "arn:aws:s3:::my-bucket/*"
        ]
      }
    ]
  })

  common_tags = {
    Project     = "MyProject"
    Environment = "production"
    Terraform   = "true"
  }
} 

## Local Testing

The module includes scripts to facilitate local testing:

### Prerequisites

- AWS CLI configured with appropriate credentials
- Bash shell environment
- Terraform installed locally

### Setting up the test environment

1. Run the setup script to create all necessary AWS resources:

```bash
./setup-test-infra.sh
```

This script will:
- Create a VPC with public and private subnets if needed
- Set up an Application Load Balancer
- Create security groups
- Create an ECS cluster
- Generate a `terraform.tfvars` file with all required values

### Running tests

Once the script completes, you can run:

```bash
terraform init -reconfigure
terraform plan
terraform apply
```

The `-reconfigure` flag is necessary because the backend configuration may change between test runs when the script recreates S3 buckets and DynamoDB tables.

### Testing with different container port and ALB port

If your application container listens on a non-standard port (e.g., 3000), but you want to expose it via the ALB on port 80, modify the generated `terraform.tfvars` file:

```hcl
container_port = 3000      # Port your application listens on
target_group_port = 80     # Port the ALB will forward traffic from
```

### Cleaning up

To remove all test resources:

```bash
./cleanup-test-infra.sh
```

This will delete all AWS resources created for testing. 