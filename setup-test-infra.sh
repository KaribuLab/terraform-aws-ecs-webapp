#!/bin/bash
# Script para crear la infraestructura base necesaria para probar el módulo ECS
# Este script debe ser ignorado por git

set -e

# Configurar AWS CLI para no usar paginador
export AWS_PAGER=""

# Función para cargar variables de un archivo .env
dotenv() {
  if [ -f .env ]; then
    echo "Cargando variables desde .env"
    set -o allexport
    source .env
    set +o allexport
  else
    echo "Archivo .env no encontrado. Utilizando valores predeterminados o variables de entorno."
  fi
}

# Cargar variables de entorno desde .env si existe
dotenv

# Comprobar que AWS CLI está instalado
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI no está instalado"
    exit 1
fi

# Asegurarse de que las variables necesarias están definidas
if [ -z "$AWS_REGION" ]; then
    echo "Definiendo región por defecto"
    export AWS_REGION="us-east-1"
fi

# Verificar si DOCKER_IMAGE está definido, si no, usar valor predeterminado
if [ -z "$DOCKER_IMAGE" ]; then
    echo "Variable DOCKER_IMAGE no definida, usando valor predeterminado: nginx:latest"
    export DOCKER_IMAGE="nginx:latest"
fi

# Verificar si CONTAINER_PORT está definido, si no, usar valor predeterminado
if [ -z "$CONTAINER_PORT" ]; then
    echo "Variable CONTAINER_PORT no definida, usando valor predeterminado: 80"
    export CONTAINER_PORT="80"
fi

echo "Usando imagen Docker: $DOCKER_IMAGE"
echo "Usando puerto de contenedor: $CONTAINER_PORT"

# Verificar si las variables VPC_ID, PUBLIC_SUBNET_IDS, y PRIVATE_SUBNET_IDS están definidas
if [ -z "$VPC_ID" ]; then
    echo "Error: VPC_ID no está definido. Por favor, especifique una VPC en el archivo .env"
    echo "Ejemplo: VPC_ID=vpc-xxxxxxxxxxxxxxxxx"
    exit 1
fi

if [ -z "$PUBLIC_SUBNET_IDS" ]; then
    echo "Error: PUBLIC_SUBNET_IDS no está definido. Por favor, especifique al menos 2 subredes públicas en el archivo .env"
    echo "Ejemplo: PUBLIC_SUBNET_IDS=subnet-xxxxxxxxx,subnet-yyyyyyyyy"
    exit 1
fi

if [ -z "$PRIVATE_SUBNET_IDS" ]; then
    echo "Error: PRIVATE_SUBNET_IDS no está definido. Por favor, especifique al menos 2 subredes privadas en el archivo .env"
    echo "Ejemplo: PRIVATE_SUBNET_IDS=subnet-xxxxxxxxx,subnet-yyyyyyyyy"
    exit 1
fi

# Convertir las listas de subredes en arrays
IFS=',' read -r -a public_subnets <<< "$PUBLIC_SUBNET_IDS"
IFS=',' read -r -a private_subnets <<< "$PRIVATE_SUBNET_IDS"

# Verificar que hay suficientes subredes (al menos 2 de cada tipo)
if [ ${#public_subnets[@]} -lt 2 ]; then
    echo "Error: Se necesitan al menos 2 subredes públicas. Solo se proporcionaron ${#public_subnets[@]}."
    exit 1
fi

if [ ${#private_subnets[@]} -lt 2 ]; then
    echo "Error: Se necesitan al menos 2 subredes privadas. Solo se proporcionaron ${#private_subnets[@]}."
    exit 1
fi

# Advertir si se utilizan las mismas subredes para público y privado
# Esto podría causar problemas ya que las tareas ECS se configuran sin IPs públicas
same_subnets=false
for priv_subnet in "${private_subnets[@]}"; do
    for pub_subnet in "${public_subnets[@]}"; do
        if [ "$priv_subnet" = "$pub_subnet" ]; then
            same_subnets=true
            echo "⚠️ ADVERTENCIA: La subred $priv_subnet se está usando tanto como subred pública como privada."
            echo "Esto puede causar problemas porque las tareas ECS necesitan estar en subredes privadas con acceso a través de NAT Gateway."
        fi
    done
done

if [ "$same_subnets" = true ]; then
    echo "⚠️ Se recomienda usar subredes diferentes para los servicios públicos (ALB) y privados (ECS)."
    echo "¿Desea continuar de todos modos? (y/n)"
    read -r response
    if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
        echo "Operación cancelada por el usuario."
        exit 1
    fi
fi

# Usar las primeras 2 subredes de cada tipo
public_subnet_1=${public_subnets[0]}
public_subnet_2=${public_subnets[1]}
private_subnet_1=${private_subnets[0]}
private_subnet_2=${private_subnets[1]}

echo "Subredes privadas para ECS: ${private_subnets[*]}"

echo "Creando infraestructura en la región $AWS_REGION"
echo "VPC: $VPC_ID"
echo "Subredes públicas: ${public_subnets[*]}"
echo "Subredes privadas: ${private_subnets[*]}"

# Verificar si tenemos al menos 2 subredes públicas para el ALB
if [ ${#public_subnets[@]} -lt 2 ]; then
    echo "Error: Se necesitan al menos 2 subredes públicas en diferentes zonas de disponibilidad para crear un ALB."
    echo "Por favor, proporcione al menos 2 subredes públicas en diferentes zonas de disponibilidad."
    echo "Puede definirlas en un archivo .env como: PUBLIC_SUBNET_IDS=subnet-xxx,subnet-yyy"
    exit 1
else
    # Continue with the original script if there are enough public subnets
    # 1. Crear el bucket de S3 para el backend de Terraform
    bucket_name="terraform-state-$(date +%s)"
    echo "Creando bucket S3 para el estado de Terraform: $bucket_name"
    aws s3 mb "s3://$bucket_name" --region "$AWS_REGION"

    # Habilitar versionamiento en el bucket
    aws s3api put-bucket-versioning \
        --bucket "$bucket_name" \
        --versioning-configuration Status=Enabled

    # Habilitar cifrado por defecto
    aws s3api put-bucket-encryption \
        --bucket "$bucket_name" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'

    # 2. Crear tabla de DynamoDB para el bloqueo de estado
    dynamodb_table="terraform-locks-$(date +%s)"
    echo "Creando tabla DynamoDB para bloqueos de estado: $dynamodb_table"
    aws dynamodb create-table \
        --table-name "$dynamodb_table" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION"

    # 3. Crear el Security Group para el ALB
    echo "Creando Security Group para el ALB..."
    alb_sg_id=$(aws ec2 create-security-group \
        --group-name "test-alb-sg-$(date +%s)" \
        --description "Security group for test ALB" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)

    echo "Security Group del ALB creado: $alb_sg_id"

    # Permitir tráfico HTTP entrante
    aws ec2 authorize-security-group-ingress \
        --group-id "$alb_sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr "0.0.0.0/0"

    echo "Configurando reglas de seguridad para comunicación ALB -> ECS..."

    # 4. Crear el Security Group para el servicio ECS
    echo "Creando Security Group para el servicio ECS..."
    ecs_sg_id=$(aws ec2 create-security-group \
        --group-name "test-ecs-sg-$(date +%s)" \
        --description "Security group for test ECS service" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)

    echo "Security Group del ECS creado: $ecs_sg_id"

    # Permitir tráfico desde el ALB hacia el servicio ECS
    aws ec2 authorize-security-group-ingress \
        --group-id "$ecs_sg_id" \
        --protocol tcp \
        --port ${CONTAINER_PORT} \
        --source-group "$alb_sg_id"

    # 5. Crear el Application Load Balancer
    echo "Creando Application Load Balancer..."
    alb_arn=$(aws elbv2 create-load-balancer \
        --name "test-alb-$(date +%s)" \
        --subnets "${public_subnets[@]}" \
        --security-groups "$alb_sg_id" \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text)

    echo "ALB creado: $alb_arn"

    # 6. Crear un Target Group por defecto (necesario para el listener)
    echo "Creando Target Group por defecto..."
    tg_arn=$(aws elbv2 create-target-group \
        --name "test-default-tg-$(date +%s)" \
        --protocol HTTP \
        --port 80 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text)

    echo "Target Group creado: $tg_arn"

    # 7. Crear un Listener HTTP
    echo "Creando Listener HTTP..."
    listener_arn=$(aws elbv2 create-listener \
        --load-balancer-arn "$alb_arn" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$tg_arn" \
        --query "Listeners[0].ListenerArn" \
        --output text)

    echo "Listener creado: $listener_arn"

    # 8. Crear el clúster ECS
    echo "Creando clúster ECS..."
    cluster_name="test-ecs-cluster-$(date +%s)"
    aws ecs create-cluster \
        --cluster-name "$cluster_name"

    echo "Clúster ECS creado: $cluster_name"

    # 9. Crear el grupo de logs en CloudWatch
    echo "Creando grupo de logs en CloudWatch..."
    service_name="test-service"
    log_group_name="/ecs/$service_name"
    aws logs create-log-group --log-group-name "$log_group_name" \
        --tags "Key=Project,Value=test-project" "Key=Environment,Value=test" "Key=Terraform,Value=true"

    aws logs put-retention-policy --log-group-name "$log_group_name" \
        --retention-in-days 7

    echo "Grupo de logs creado: $log_group_name"

    # Verificar si terraform.tfvars ya existe, y eliminarlo
    if [ -f terraform.tfvars ]; then
        echo "Eliminando archivo terraform.tfvars existente..."
        rm terraform.tfvars
    fi
    
    # Generar el archivo terraform.tfvars para las pruebas
    cat > terraform.tfvars << EOF
# Configuración básica del servicio
cluster_name   = "${cluster_name}"
service_name   = "test-service"
docker_image   = "${DOCKER_IMAGE}"

# Configuración de puertos
container_port = ${CONTAINER_PORT}

# Recursos asignados al contenedor
task_cpu       = "256"
task_memory    = "512"

# ¡IMPORTANTE! - Configuración de red
# Usar SOLO subredes PRIVADAS para el servicio ECS
# ECS tasks need to be in private subnets to properly communicate with other AWS services
# and download Docker images through the NAT Gateway, as they are configured without public IPs
subnet_ids     = [$(printf '"%s",' "${private_subnets[@]}" | sed 's/,$//')]
vpc_id         = "${VPC_ID}"
alb_listener_arn = "${listener_arn}"

# Configuración de seguridad
alb_security_group_id = "${alb_sg_id}"  # ID del security group del ALB
create_security_group_rules = true
# allowed_cidr_blocks = ["0.0.0.0/0"]  # Descomentarlo si necesitas acceso desde Internet

# Configuración de CloudWatch logs
cloudwatch_log_group_name = "${log_group_name}"

health_check = {
  path                = "/"
  interval            = 30
  timeout             = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
  matcher             = "200-399"
}

environment_variables = [
  {
    name  = "PORT"
    value = "${CONTAINER_PORT}"
  },
  {
    name  = "ENV"
    value = "test"
  }
]

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
  Project     = "test-project"
  Environment = "test"
  Terraform   = "true"
}
EOF

    echo "Archivo terraform.tfvars generado exitosamente."
    echo ""
    echo "Configurando servicio ECS para usar las siguientes subredes PRIVADAS:"
    
    # Verificar si jq está instalado
    if command -v jq &> /dev/null; then
        for subnet in "${private_subnets[@]}"; do
            subnet_info=$(aws ec2 describe-subnets --subnet-ids "$subnet" --query "Subnets[0].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" --output json 2>/dev/null || echo "{}")
            if [ "$subnet_info" != "{}" ]; then
                echo "$subnet_info" | jq -r '"  - Subnet ID: " + .ID + " (AZ: " + .AZ + ", CIDR: " + .CIDR + ")"' 2>/dev/null || echo "  - $subnet (información no disponible)"
            else
                echo "  - $subnet (información no disponible)"
            fi
        done
    else
        # Formato simple si jq no está disponible
        echo "  ${private_subnets[*]}"
        echo "  (Para más detalles, instale jq: apt-get install jq o yum install jq)"
    fi
    echo ""

    # Generar el archivo backend.tf para las pruebas
    cat > backend.tf << EOF
terraform {
  backend "s3" {
    bucket         = "${bucket_name}"
    key            = "terraform.tfstate"
    region         = "${AWS_REGION}"
    dynamodb_table = "${dynamodb_table}"
    encrypt        = true
  }
}
EOF

    # Verificar si cleanup-test-infra.sh ya existe, y eliminarlo
    if [ -f cleanup-test-infra.sh ]; then
        echo "Eliminando script cleanup-test-infra.sh existente..."
        rm cleanup-test-infra.sh
    fi

    # Script para limpiar los recursos
    cat > cleanup-test-infra.sh << EOF
#!/bin/bash
# Script para eliminar los recursos creados para pruebas

set -e

# Configurar AWS CLI para no usar paginador
export AWS_PAGER=""

# Función para cargar variables de un archivo .env
dotenv() {
  if [ -f .env ]; then
    set -o allexport
    source .env
    set +o allexport
  fi
}

# Cargar variables de entorno desde .env si existe
dotenv

echo "Eliminando los recursos de prueba..."

# Cargar variables
CLUSTER_NAME="${cluster_name}"
ECS_SG_ID="${ecs_sg_id}"
ALB_ARN="${alb_arn}"
ALB_LISTENER_ARN="${listener_arn}"
ALB_SG_ID="${alb_sg_id}"
DYNAMODB_TABLE="${dynamodb_table}"
BUCKET_NAME="${bucket_name}"
AWS_REGION="${AWS_REGION}"

# Función para detener y eliminar tareas y servicios ECS
cleanup_ecs_resources() {
  local cluster=\$1
  echo "Iniciando limpieza de recursos en el clúster ECS: \$cluster"
  
  # Verificar si el clúster existe
  if ! aws ecs describe-clusters --clusters \$cluster --query "clusters[0].status" --output text 2>/dev/null | grep -q ACTIVE; then
    echo "El clúster \$cluster no existe o no está activo. Saltando la limpieza de ECS."
    return 0
  fi
  
  # Listar todos los servicios
  echo "Buscando servicios ECS en el clúster \$cluster..."
  local services=\$(aws ecs list-services --cluster \$cluster --query "serviceArns" --output text 2>/dev/null || echo "")
  
  if [ -n "\$services" ] && [ "\$services" != "None" ]; then
    echo "Servicios encontrados. Deteniendo servicios..."
    for service in \$(echo \$services | tr '\t' '\n'); do
      if [ -n "\$service" ]; then
        echo "Actualizando servicio a 0 tareas: \$service"
        aws ecs update-service --cluster \$cluster --service \$service --desired-count 0 --no-force-new-deployment || true
      fi
    done
    
    # Esperar un momento para que se actualice el servicio
    echo "Esperando 10 segundos para que los servicios actualicen su estado..."
    sleep 10
    
    # Listar tareas en ejecución
    echo "Buscando tareas en ejecución..."
    local tasks=\$(aws ecs list-tasks --cluster \$cluster --query "taskArns" --output text 2>/dev/null || echo "")
    
    if [ -n "\$tasks" ] && [ "\$tasks" != "None" ]; then
      echo "Tareas encontradas. Deteniendo tareas..."
      for task in \$(echo \$tasks | tr '\t' '\n'); do
        if [ -n "\$task" ]; then
          echo "Deteniendo tarea: \$task"
          aws ecs stop-task --cluster \$cluster --task \$task || true
        fi
      done
      
      # Esperar a que las tareas se detengan
      echo "Esperando 15 segundos para que las tareas se detengan..."
      sleep 15
    else
      echo "No se encontraron tareas en ejecución."
    fi
    
    # Eliminar servicios
    echo "Eliminando servicios ECS..."
    for service in \$(echo \$services | tr '\t' '\n'); do
      if [ -n "\$service" ]; then
        echo "Eliminando servicio: \$service"
        aws ecs delete-service --cluster \$cluster --service \$service --force || true
      fi
    done
    
    # Esperar a que los servicios se eliminen
    echo "Esperando 10 segundos para que los servicios se eliminen..."
    sleep 10
  else
    echo "No se encontraron servicios en el clúster."
  fi
  
  # Intentar eliminar el clúster
  echo "Eliminando clúster ECS: \$cluster"
  aws ecs delete-cluster --cluster \$cluster || {
    echo "Error al eliminar el clúster. Verificando nuevamente el estado..."
    
    # Verificar si hay tareas restantes
    local remaining_tasks=\$(aws ecs list-tasks --cluster \$cluster --query "taskArns" --output text 2>/dev/null || echo "")
    if [ -n "\$remaining_tasks" ] && [ "\$remaining_tasks" != "None" ]; then
      echo "Aún hay tareas pendientes. Intentando forzar la detención..."
      for task in \$(echo \$remaining_tasks | tr '\t' '\n'); do
        if [ -n "\$task" ]; then
          echo "Forzando detención de tarea: \$task"
          aws ecs stop-task --cluster \$cluster --task \$task || true
        fi
      done
      echo "Esperando 20 segundos antes de intentar eliminar el clúster nuevamente..."
      sleep 20
      aws ecs delete-cluster --cluster \$cluster || echo "⚠️ No se pudo eliminar el clúster \$cluster. Es posible que necesite eliminarlo manualmente."
    else
      echo "⚠️ No se pudo eliminar el clúster a pesar de no tener tareas visibles. Es posible que necesite eliminarlo manualmente."
    fi
  }
}

# Limpiar recursos ECS
cleanup_ecs_resources "\$CLUSTER_NAME"

# Eliminar el listener
echo "Eliminando listener: \$ALB_LISTENER_ARN"
aws elbv2 delete-listener --listener-arn \$ALB_LISTENER_ARN || echo "⚠️ No se pudo eliminar el listener"

# Eliminar los target groups
echo "Eliminando target groups..."
aws elbv2 describe-target-groups --query "TargetGroups[?LoadBalancerArns[0]=='\$ALB_ARN'].TargetGroupArn" --output text | tr '\t' '\n' | while read tg; do
  if [ -n "\$tg" ]; then
    echo "Eliminando target group: \$tg"
    aws elbv2 delete-target-group --target-group-arn \$tg || echo "⚠️ No se pudo eliminar el target group \$tg"
  fi
done

# Eliminar el ALB
echo "Eliminando ALB: \$ALB_ARN"
aws elbv2 delete-load-balancer --load-balancer-arn \$ALB_ARN || echo "⚠️ No se pudo eliminar el ALB"

# Esperar a que el ALB se elimine
echo "Esperando a que el ALB se elimine..."
sleep 30

# Eliminar security groups
echo "Eliminando security group de ECS: \$ECS_SG_ID"
aws ec2 delete-security-group --group-id \$ECS_SG_ID || echo "⚠️ No se pudo eliminar el security group de ECS"

echo "Eliminando security group de ALB: \$ALB_SG_ID"
aws ec2 delete-security-group --group-id \$ALB_SG_ID || echo "⚠️ No se pudo eliminar el security group del ALB"

echo "Eliminando la tabla DynamoDB: \$DYNAMODB_TABLE"
aws dynamodb delete-table --table-name "\$DYNAMODB_TABLE" --region "\$AWS_REGION" || echo "⚠️ No se pudo eliminar la tabla DynamoDB"

# Eliminar el bucket S3 (primero hay que vaciarlo)
echo "Vaciando y eliminando bucket S3: \$BUCKET_NAME"
if aws s3 ls "s3://\$BUCKET_NAME" &>/dev/null; then
  echo "Vaciando el bucket \$BUCKET_NAME..."
  # Eliminar versiones antiguas y marcadores de eliminación
  aws s3api list-object-versions --bucket "\$BUCKET_NAME" --output text --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' | while read key versionid; do
    if [ ! -z "\$key" ] && [ ! -z "\$versionid" ]; then
      echo "Eliminando objeto con clave \$key (marcador de eliminación, versión \$versionid)"
      aws s3api delete-object --bucket "\$BUCKET_NAME" --key "\$key" --version-id "\$versionid" || true
    fi
  done
  
  aws s3api list-object-versions --bucket "\$BUCKET_NAME" --output text --query 'Versions[].{Key:Key,VersionId:VersionId}' | while read key versionid; do
    if [ ! -z "\$key" ] && [ ! -z "\$versionid" ]; then
      echo "Eliminando objeto con clave \$key (versión \$versionid)"
      aws s3api delete-object --bucket "\$BUCKET_NAME" --key "\$key" --version-id "\$versionid" || true
    fi
  done
  
  # Eliminar archivos restantes (por si acaso)
  aws s3 rm "s3://\$BUCKET_NAME" --recursive --force || echo "⚠️ No se pudieron eliminar todos los objetos del bucket"
  
  # Eliminar el bucket
  echo "Eliminando el bucket \$BUCKET_NAME..."
  aws s3 rb "s3://\$BUCKET_NAME" --force || echo "⚠️ No se pudo eliminar el bucket S3"
else
  echo "El bucket \$BUCKET_NAME no existe o no es accesible"
fi

echo "Limpieza completada."
EOF

    chmod +x cleanup-test-infra.sh

    # Mostrar información sobre cómo usar la infraestructura creada
    echo ""
    echo "=========================== INFRAESTRUCTURA CREADA ==========================="
    echo "Se ha creado la siguiente infraestructura para pruebas:"
    echo ""
    echo "Bucket S3 para backend: $bucket_name"
    echo "Tabla DynamoDB para bloqueos: $dynamodb_table"
    echo "Security Group ALB: $alb_sg_id"
    echo "Security Group ECS: $ecs_sg_id"
    echo "ALB ARN: $alb_arn"
    echo "Listener ARN: $listener_arn"
    echo "Clúster ECS: $cluster_name"
    echo ""
    echo "Subredes PRIVADAS para ECS: ${private_subnets[*]}"
    echo ""
    echo "Se ha generado un archivo 'terraform.tfvars' con los valores para probar el módulo."
    echo "También se ha generado el archivo 'backend.tf' para usar el estado remoto."
    echo ""
    echo "IMPORTANTE: El servicio ECS está configurado para usar solo subredes PRIVADAS."
    echo "Esto significa que no tendrá acceso directo a Internet, y la comunicación ocurrirá a través del ALB."
    echo ""
    echo "Para usar el módulo, ejecuta:"
    echo "terraform init -reconfigure"
    echo "terraform plan"
    echo "terraform apply"
    echo ""
    echo "Para eliminar la infraestructura de prueba, ejecuta ./cleanup-test-infra.sh"
    echo "==========================================================================="
fi

# Crear un archivo de ejemplo .env
cat > .env.example << EOF
# Variables para el script de configuración de pruebas
# Copiar a .env y modificar según sea necesario

# Región de AWS
AWS_REGION=us-east-1

# Si estos valores no se proporcionan, el script creará automáticamente una VPC y subredes
# ID de la VPC donde se crearán los recursos
# VPC_ID=vpc-xxxxxxxxxxxxxxxxx

# Lista de subredes públicas (separadas por comas)
# IMPORTANTE: Se necesitan al menos 2 subredes públicas en diferentes zonas de disponibilidad para crear un ALB
# PUBLIC_SUBNET_IDS=subnet-xxxxxxxxxxxxxxxxx,subnet-yyyyyyyyyyyyyyyyy

# Lista de subredes privadas (separadas por comas)
# PRIVATE_SUBNET_IDS=subnet-xxxxxxxxxxxxxxxxx,subnet-yyyyyyyyyyyyyyyyy
EOF