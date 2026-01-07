# Terraform AWS ECS WebApp

Este módulo crea un servicio ECS Fargate para desplegar aplicaciones web con balanceo de carga.

## Inputs

| Name                              | Type         | Description                                                              | Required |
| --------------------------------- | ------------ | ------------------------------------------------------------------------ | -------- |
| cluster_name                      | string       | Name of the ECS Cluster                                                  | yes      |
| service_name                      | string       | Name of the ECS service                                                  | yes      |
| docker_image                      | string       | Docker image in ECR                                                      | yes      |
| image_tag                         | string       | Image tag (default: "latest")                                            | no       |
| container_port                    | number       | Port exposed by the container                                            | yes      |
| task_cpu                          | string       | Amount of CPU for the ECS task (in CPU units)                            | yes      |
| task_memory                       | string       | Amount of memory for the ECS task (in MiB)                               | yes      |
| subnet_ids                        | list(string) | IDs of private subnets for ECS tasks. IMPORTANT: Must be private subnets as tasks are configured without public IPs | yes      |
| vpc_id                            | string       | VPC ID where resources will be created                                   | yes      |
| alb_listener_arn                  | string       | ARN of the ALB listener (HTTP or HTTPS)                                  | yes      |
| alb_security_group_id             | string       | ID del security group del Application Load Balancer                      | yes      |
| service_discovery                 | object       | Service Discovery configuration for the ECS service                      | no       |
| environment_variables             | list(object) | [Environment variables](#environment-variables) to pass to the container | no       |
| health_check                      | object       | [Health check configuration](#health-check)                              | yes      |
| listener_rules                    | list(object) | [List of listener rules](#listener-rules)                                | no       |
| autoscaling_config                | object       | [Auto scaling configuration](#autoscaling-config)                        | yes      |
| common_tags                       | map(string)  | Common tags to be applied to all resources                               | yes      |
| task_policy_json                  | string       | IAM Policy document in JSON format for the task role                     | no       |
| target_group_deregistration_delay | number       | Time for ELB to wait before deregistering targets                        | no       |
| force_new_deployment              | bool         | Force a new deployment of the service                                    | no       |
| deployment_config                 | object       | [Deployment configuration](#deployment-config)                           | yes      |
| enable_deployment_circuit_breaker | bool         | Enable deployment circuit breaker with rollback                          | no       |
| cloudwatch_log_group_name         | string       | Full name of the CloudWatch Log Group to use (e.g. /ecs/service-name)    | no       |

### Environment Variables

| Name  | Type   | Description                       | Required |
| ----- | ------ | --------------------------------- | -------- |
| name  | string | Name of the environment variable  | yes      |
| value | string | Value of the environment variable | yes      |

### Service Discovery Configuration

| Name        | Type   | Description                                  | Required |
| ----------- | ------ | -------------------------------------------- | -------- |
| namespace_id | string | ID of the Service Discovery namespace        | yes      |
| dns         | object | [DNS configuration](#dns-configuration)      | yes      |

#### DNS Configuration

| Name | Type   | Description                                     | Required |
| ---- | ------ | ----------------------------------------------- | -------- |
| name | string | DNS name for the service                        | yes      |
| type | string | Type of DNS record (e.g., A, SRV)               | yes      |
| ttl  | number | Time-to-live value for the DNS record (seconds) | yes      |

### Health Check

| Name                | Type   | Description                                 | Required |
| ------------------- | ------ | ------------------------------------------- | -------- |
| path                | string | Path for the health check                   | yes      |
| interval            | number | Interval between health checks              | yes      |
| timeout             | number | Timeout for the health check                | yes      |
| healthy_threshold   | number | Threshold to consider the task as healthy   | yes      |
| unhealthy_threshold | number | Threshold to consider the task as unhealthy | yes      |
| matcher             | string | HTTP codes considered as success            | yes      |

### Listener Rules

| Name          | Type         | Description                | Required |
| ------------- | ------------ | -------------------------- | -------- |
| priority      | number       | Rule priority              | yes      |
| path_patterns | list(string) | Path patterns for the rule | no       |
| host_headers  | list(string) | Host headers for the rule  | no       |

Al menos uno de `path_patterns` o `host_headers` debe ser proporcionado.

### Autoscaling Config

| Name             | Type   | Description                                                                 | Required |
| ---------------- | ------ | --------------------------------------------------------------------------- | -------- |
| min_capacity     | number | Minimum task capacity                                                      | yes      |
| max_capacity     | number | Maximum task capacity                                                      | yes      |
| cpu              | object | [CPU autoscaling configuration](#cpu-autoscaling-configuration)             | no       |
| memory           | object | [Memory autoscaling configuration](#memory-autoscaling-configuration)       | no       |
| alb_request_count| object | [ALB request count autoscaling configuration](#alb-request-count-configuration) | no       |

At least one of `cpu`, `memory`, or `alb_request_count` must be provided. When `min_capacity = 0`, `alb_request_count` is required to enable automatic scaling from 0.

#### CPU Autoscaling Configuration

| Name               | Type   | Description                              | Required |
| ------------------ | ------ | ---------------------------------------- | -------- |
| target_value       | number | Target CPU utilization value for scaling | yes      |
| scale_in_cooldown  | number | Cool-down time for scaling in (seconds)  | yes      |
| scale_out_cooldown | number | Cool-down time for scaling out (seconds) | yes      |

#### Memory Autoscaling Configuration

| Name               | Type   | Description                                 | Required |
| ------------------ | ------ | ------------------------------------------- | -------- |
| target_value       | number | Target memory utilization value for scaling | yes      |
| scale_in_cooldown  | number | Cool-down time for scaling in (seconds)     | yes      |
| scale_out_cooldown | number | Cool-down time for scaling out (seconds)    | yes      |

#### ALB Request Count Autoscaling Configuration

| Name               | Type   | Description                                                                    | Required |
| ------------------ | ------ | ------------------------------------------------------------------------------ | -------- |
| target_value       | number | Target number of requests per target for scaling (e.g., 100 requests per task) | yes      |
| scale_in_cooldown  | number | Cool-down time for scaling in (seconds)                                        | yes      |
| scale_out_cooldown | number | Cool-down time for scaling out (seconds)                                       | yes      |

This policy uses ALB metrics (`ALBRequestCountPerTarget`) which are available even when there are 0 tasks, enabling automatic scaling from 0. **Required when `min_capacity = 0`**.

### ⚠️ Consideraciones sobre Escalado a 0 (min_capacity = 0)

El módulo **técnicamente permite** escalar a 0 tareas (`min_capacity = 0`), pero hay consideraciones importantes:

**Limitaciones cuando min_capacity = 0:**

1. **Target Group sin targets**: Cuando el servicio escala a 0, el Target Group del ALB no tendrá targets saludables, causando errores **503 (Service Unavailable)** para todas las solicitudes entrantes hasta que el servicio escale nuevamente.

2. **Métricas no disponibles**: Las políticas de autoscaling basadas en CPU y memoria (`ECSServiceAverageCPUUtilization` y `ECSServiceAverageMemoryUtilization`) requieren que haya al menos una tarea ejecutándose para generar métricas. Cuando hay 0 tareas:
   - No se generan métricas de CPU/memoria
   - Las políticas de CPU/Memoria no pueden escalar desde 0 automáticamente

3. **Cold start**: Cuando el servicio escala desde 0, habrá un retraso (cold start) antes de que las tareas estén listas para recibir tráfico.

**Solución: Política basada en ALB Request Count**

Para habilitar el escalado automático desde 0, **debe proporcionar `alb_request_count`** cuando `min_capacity = 0`. Esta política usa métricas del ALB (`ALBRequestCountPerTarget`) que están disponibles incluso sin tareas ejecutándose, permitiendo que el servicio escale automáticamente cuando lleguen solicitudes.

**Recomendaciones:**

- **Producción con ALB**: Use `min_capacity = 1` para garantizar disponibilidad continua, o use `min_capacity = 0` con `alb_request_count` configurado
- **Desarrollo/Testing**: `min_capacity = 0` con `alb_request_count` es útil para ahorrar costos cuando no hay tráfico
- **Políticas combinadas**: Puede usar `alb_request_count` junto con `cpu` y/o `memory`. AWS Application Auto Scaling evaluará todas las políticas y usará la que requiera más capacidad

### Deployment Config

| Name                    | Type   | Description                                           | Required |
| ----------------------- | ------ | ----------------------------------------------------- | -------- |
| maximum_percent         | number | Maximum percentage of tasks during deployment         | yes      |
| minimum_healthy_percent | number | Minimum percentage of healthy tasks during deployment | yes      |

## Outputs

| Name                    | Type   | Description                                       |
| ----------------------- | ------ | ------------------------------------------------- |
| alb_target_group_arn    | string | ARN of the Target Group connected to the ALB      |
| ecs_service_name        | string | Name of the ECS service                           |
| ecs_task_definition_arn | string | ARN of the ECS task definition                    |
| iam_execution_role_arn  | string | ARN of the ECS execution role                     |
| cluster_name            | string | Name of the ECS cluster                           |
| service_name            | string | Name of the ECS service                           |
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
  alb_security_group_id = "sg-alb123456"  # ID of the ALB security group

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
    cpu = {
      target_value       = 50
      scale_in_cooldown  = 60
      scale_out_cooldown = 60
    }
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

#### Configuración con escalado por CPU y memoria
```hcl
module "ecs_webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  // ... configuración básica ...

  autoscaling_config = {
    min_capacity       = 1
    max_capacity       = 5
    cpu = {
      target_value       = 70
      scale_in_cooldown  = 300
      scale_out_cooldown = 60
    }
    memory = {
      target_value       = 80
      scale_in_cooldown  = 300
      scale_out_cooldown = 60
    }
  }

  // ... otras configuraciones ...
}
```

#### Configuración con reglas de listener personalizadas
```hcl
module "ecs_webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  // ... configuración básica ...

  listener_rules = [
    {
      priority      = 100
      path_patterns = ["/api/*"]
    },
    {
      priority     = 200
      host_headers = ["api.example.com"]
    }
  ]

  // ... otras configuraciones ...
}
```

#### Configuración con Service Discovery
```hcl
module "ecs_webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  // ... configuración básica ...

  service_discovery = {
    namespace_id = "ns-abc123def456"
    dns = {
      name = "api"
      type = "A"
      ttl  = 300
    }
  }

  // ... otras configuraciones ...
}
```

#### Configuración con escalado a 0 usando ALB Request Count
```hcl
module "ecs_webapp" {
  source = "github.com/your-username/terraform-aws-ecs-webapp"

  // ... configuración básica ...

  autoscaling_config = {
    min_capacity       = 0  # Permite escalar a 0 tareas
    max_capacity       = 10
    # ALB request count es requerido cuando min_capacity = 0
    alb_request_count = {
      target_value       = 100  # Escala cuando hay más de 100 requests por target
      scale_in_cooldown  = 300  # Espera 5 minutos antes de reducir
      scale_out_cooldown = 60  # Espera 1 minuto antes de aumentar
    }
    # Opcional: también puede incluir políticas de CPU/Memoria
    # Estas funcionarán cuando haya tareas ejecutándose
    cpu = {
      target_value       = 70
      scale_in_cooldown  = 300
      scale_out_cooldown = 60
    }
  }

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

## Testing

El módulo incluye pruebas automatizadas usando [Terratest](https://terratest.gruntwork.io/) que verifican que todos los recursos se crean correctamente.

### Ejecutar Pruebas con Terratest

Las pruebas crean automáticamente toda la infraestructura necesaria (VPC, ALB, ECS cluster, etc.), aplican el módulo, verifican los recursos y limpian todo al finalizar.

#### Prerrequisitos

- Go 1.21 o superior
- Terraform >= 1.0
- AWS CLI configurado con credenciales apropiadas
- Permisos AWS para crear:
  - VPC, Subnets, Internet Gateway, NAT Gateway
  - Application Load Balancer
  - ECS Cluster y Services
  - IAM Roles y Policies
  - Security Groups
  - CloudWatch Log Groups
  - Application Auto Scaling resources

#### Configuración de Credenciales AWS

Asegúrate de tener credenciales AWS configuradas. Puedes usar cualquiera de estos métodos:

**Opción 1: Variables de entorno**
```bash
export AWS_ACCESS_KEY_ID="tu-access-key"
export AWS_SECRET_ACCESS_KEY="tu-secret-key"
export AWS_DEFAULT_REGION="us-east-1"
```

**Opción 2: Archivo de credenciales (~/.aws/credentials)**
```bash
aws configure
```

**Opción 3: Perfil de AWS**
```bash
export AWS_PROFILE="tu-perfil"
```

#### Instalar Dependencias

Desde la raíz del proyecto:

```bash
go mod download
```

#### Ejecutar Todas las Pruebas

```bash
cd test
go test -v -timeout 60m
```

#### Ejecutar Pruebas Específicas

```bash
cd test
# Ejecutar solo pruebas del servicio ECS
go test -v -timeout 60m -run TestTerraformModule/ECS_Service

# Ejecutar solo pruebas de autoscaling
go test -v -timeout 60m -run TestTerraformModule/Autoscaling
```

#### Configuración Personalizada

Puedes personalizar la configuración con variables de entorno:

```bash
export AWS_DEFAULT_REGION="us-west-2"  # Región AWS
export ECR_REPOSITORY="nginx"          # Imagen Docker (default: nginx)
export IMAGE_TAG="latest"              # Tag de imagen (default: latest)
export CONTAINER_PORT="80"             # Puerto del contenedor (default: 80)

cd test
go test -v -timeout 60m
```

#### Qué Esperar

Las pruebas:
1. **Crean infraestructura base** (VPC, ALB, ECS cluster) - ~5-10 minutos
2. **Aplican el módulo Terraform** - ~2-5 minutos
3. **Ejecutan verificaciones** - ~1-2 minutos
4. **Destruyen todo automáticamente** - ~5-10 minutos

**Tiempo total estimado**: 15-30 minutos

#### Cobertura de Pruebas

Las pruebas verifican:
- ✅ Creación y configuración del servicio ECS
- ✅ Task Definition con configuración correcta de contenedores
- ✅ Configuración del Target Group y health checks
- ✅ Políticas de Auto Scaling (CPU-based)
- ✅ IAM Execution Role con políticas correctas
- ✅ Security Groups con reglas de ingreso/egreso apropiadas
- ✅ Todos los outputs del módulo son válidos

#### Consideraciones de Costos

⚠️ **Advertencia**: Las pruebas crean recursos reales en AWS y generarán costos:
- VPC con NAT Gateway (~$0.045/hora)
- Application Load Balancer (~$0.0225/hora)
- ECS Fargate tasks (~$0.04/vCPU-hora + ~$0.004/GB-hora)
- Costos de transferencia de datos

**Costo estimado por ejecución de pruebas**: $0.10 - $0.50

#### Troubleshooting

**Error: "AWS credentials not found"**
```bash
# Verifica tus credenciales
aws sts get-caller-identity
```

**Error: "timeout"**
```bash
# Aumenta el timeout
go test -v -timeout 90m
```

**Error: "Resource Already Exists"**
- Asegúrate de que ejecuciones anteriores completaron la limpieza
- Verifica recursos huérfanos en AWS Console
- Los nombres de recursos incluyen timestamps aleatorios para evitar conflictos

Para más detalles, consulta [test/README.md](test/README.md).

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