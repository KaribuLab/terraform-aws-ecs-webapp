# Terraform AWS ECS WebApp

This module creates an ECS Fargate service for deploying web applications with load balancing.

## Inputs

| Name                           | Type          | Description                                                  | Required |
| ------------------------------ | ------------- | ------------------------------------------------------------ | -------- |
| cluster_name                   | string        | Name of the ECS Cluster                                      | yes      |
| service_name                   | string        | Name of the ECS service                                      | yes      |
| docker_image                   | string        | Docker image in ECR (repository URL without tag)             | yes      |
| image_tag                      | string        | Image tag (default: "latest")                                | no       |
| container_port                 | number        | Port exposed by the container                                | yes      |
| task_cpu                       | string        | Amount of CPU for the ECS task (in CPU units)                | yes      |
| task_memory                    | string        | Amount of memory for the ECS task (in MiB)                   | yes      |
| subnet_ids                     | list(string)  | IDs of the private subnets for ECS tasks                     | yes      |
| vpc_id                         | string        | VPC ID where resources will be created                       | yes      |
| alb_listener_arn               | string        | ARN of the ALB listener (HTTP or HTTPS)                      | yes      |
| alb_security_group_id          | string        | ID del security group del Application Load Balancer          | yes      |
| environment_variables          | list(object)  | [Environment variables](#environment-variables) to pass to the container | no |
| health_check                   | object        | [Health check configuration](#health-check)                  | yes      |
| listener_rules                 | list(object)  | [List of listener rules](#listener-rules)                    | no       |
| autoscaling_config             | object        | [Auto scaling configuration](#autoscaling-config)            | yes      |
| common_tags                    | map(string)   | Common tags to be applied to all resources                   | yes      |
| task_policy_json               | string        | IAM Policy document in JSON format for the task role         | no       |
| target_group_deregistration_delay | number     | Time for ELB to wait before deregistering targets            | no       |
| force_new_deployment           | bool          | Force a new deployment of the service                        | no       |
| deployment_config              | object        | [Deployment configuration](#deployment-config)               | yes      |
| enable_deployment_circuit_breaker | bool       | Enable deployment circuit breaker with rollback              | no       |
| cloudwatch_log_group_name      | string        | Full name of the CloudWatch Log Group to use (e.g. /ecs/service-name) | no |

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
| security_group_id       | string | ID of the security group used for the ECS service |

## Ejemplos adicionales

### Configuraciones comunes

#### Despliegue básico
```hcl
module "ecs_webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  cluster_name        = "my-cluster"
  service_name        = "my-webapp"
  docker_image        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repository"
  image_tag           = "v1.0.0"
  container_port      = 80
  task_cpu            = "256"
  task_memory         = "512"
  subnet_ids          = ["subnet-abcdef", "subnet-123456"]
  vpc_id              = "vpc-abcdef123"
  alb_listener_arn    = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/my-alb/abcdef/123456789"
  alb_security_group_id = "sg-alb123456"  # ID del security group del ALB

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
    max_capacity       = 2
    target_value       = 50
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }

  deployment_config = {
    maximum_percent         = 200
    minimum_healthy_percent = 100
  }

  common_tags = {
    Project     = "MyProject"
    Environment = "production"
  }
}
```

#### Reglas de seguridad personalizadas
```hcl
module "ecs_webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  // ... configuración básica ...

  # Reglas de seguridad
  alb_security_group_id = "sg-alb123456"  # ID del security group del ALB

  // ... otras configuraciones ...
}
```

### Security Group Configuration

El módulo ahora siempre crea un security group dedicado para el servicio ECS y configura automáticamente las reglas de ingreso, lo que simplifica la configuración y mejora la seguridad.

El security group permite tráfico únicamente desde el ALB al puerto del contenedor:

```hcl
# Configuración del security group para permitir tráfico desde el ALB
alb_security_group_id = "sg-alb123456"  # ID del security group del ALB
```

## Local Testing

The module includes scripts to facilitate local testing:

### Prerequisites

- AWS CLI configured with appropriate credentials
- Bash shell environment
- Terraform installed locally

### Setting up the test environment

1. (Optional) Create a `.env` file to customize your test environment:

```bash
# Copy from the .env.example file
cp .env.example .env
```

2. Customize the `.env` file with your preferred settings. You can define:
   - AWS region
   - Docker image repository and image tag for testing
   - Container port
   - Target group port
   - VPC and subnet IDs (optional)

```bash
# Example .env configuration
AWS_REGION=us-east-1
DOCKER_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repository
IMAGE_TAG=latest
CONTAINER_PORT=80
TARGET_GROUP_PORT=80
```

3. Run the setup script to create all necessary AWS resources:

```bash
./setup-test-infra.sh
```

This script will:
- Create a VPC with public and private subnets if needed
- Set up an Application Load Balancer
- Create security groups
- Create an ECS cluster
- Create a CloudWatch Log Group for the ECS service
- Generate a `terraform.tfvars` file with all required values
- Generate a cleanup script to remove all resources later

### Running tests

Once the script completes, you can run:

```bash
terraform init -reconfigure
terraform plan
terraform apply
```

The `-reconfigure` flag is necessary because the backend configuration may change between test runs when the script recreates S3 buckets and DynamoDB tables.

### Container Port Configuration

The target group and the load balancer will always forward traffic to the same port that your container exposes. This simplifies configuration and ensures consistency.

If your application container listens on a non-standard port (e.g., 3000), simply set the container port in your `.env` file:

```bash
# Configuración para la imagen Docker y el puerto del contenedor
DOCKER_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/my-application
IMAGE_TAG=v1.0.0  # El módulo utilizará DOCKER_IMAGE:IMAGE_TAG 
CONTAINER_PORT=3000
```

The module will combine the Docker image repository and tag (`DOCKER_IMAGE:IMAGE_TAG`) and configure the target group to forward traffic to port 3000.

### Network Configuration

The ECS service is configured to use only **private subnets**. This ensures your containers aren't directly accessible from the internet, and all traffic flows through the Application Load Balancer.

### CloudWatch Logs

All ECS tasks automatically send their logs to CloudWatch. The module expects an existing CloudWatch Log Group to be available before deploying the ECS service.

The recommended setup is to:

1. Create the CloudWatch Log Group using the `setup-test-infra.sh` script or manually before deploying
2. Pass the log group name to the module using the `cloudwatch_log_group_name` variable

```hcl
# Example:
cloudwatch_log_group_name = "/ecs/my-service"
```

This approach prevents `ResourceInitializationError` when the container tries to write logs to a non-existent log group.

### Cleaning up

To remove all test resources:

```bash
./cleanup-test-infra.sh
```

This will:
- Stop and delete all ECS tasks and services
- Remove the ECS cluster
- Delete all load balancer components
- Remove security groups
- Delete the S3 bucket used for Terraform state (including all versions)
- Remove the DynamoDB table used for state locking 

## Private Subnets for ECS Tasks

This module configures ECS tasks without public IP addresses (`assign_public_ip = false`). Therefore, it is **mandatory** to provide private subnets in the `subnet_ids` variable.

### Why Private Subnets?

1. **Security**: Private subnets are not directly accessible from the Internet.
2. **Correct Architecture**: ECS tasks should be in private subnets that can access the Internet through a NAT Gateway.
3. **Docker Image Downloads**: Although tasks don't have a public IP, they need to access the Internet to download Docker images, which is accomplished through the NAT Gateway.

If public subnets are used without assigning a public IP, the tasks will not start correctly because they won't be able to download Docker images or communicate with other AWS services.

**Recommended Network Configuration:**
- **ALB**: In public subnets
- **ECS Tasks**: In private subnets with Internet access through a NAT Gateway 