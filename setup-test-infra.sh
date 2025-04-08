#!/bin/bash
# Script para crear la infraestructura base necesaria para probar el módulo ECS
# Este script debe ser ignorado por git

set -e

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

# Función para crear VPC y subredes si no están definidas
create_vpc_and_subnets() {
    echo "Creando VPC y subredes automáticamente..."
    
    # Intentar crear VPC
    echo "Intentando crear una nueva VPC..."
    vpc_id=$(aws ec2 create-vpc \
        --cidr-block 10.0.0.0/16 \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=terraform-test-vpc}]" \
        --query "Vpc.VpcId" \
        --output text 2>/dev/null || echo "ERROR_CREATING_VPC")
    
    # Si no se puede crear la VPC, buscar una existente
    if [ "$vpc_id" = "ERROR_CREATING_VPC" ]; then
        echo "No se pudo crear una nueva VPC. Buscando VPCs existentes..."
        vpc_id=$(aws ec2 describe-vpcs \
            --query "Vpcs[0].VpcId" \
            --output text)
        
        if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
            echo "Error: No se encontraron VPCs existentes. Por favor, especifique una VPC en el archivo .env"
            exit 1
        fi
        
        echo "Usando VPC existente: $vpc_id"
        
        # Obtener subredes existentes en la VPC específica
        echo "Buscando subredes existentes en la VPC..."
        
        # Obtener todas las subredes de la VPC
        all_subnets=($(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query "Subnets[].SubnetId" \
            --output text))
        
        if [ ${#all_subnets[@]} -lt 2 ]; then
            echo "Error: No se encontraron suficientes subredes en la VPC. Se necesitan al menos 2 subredes."
            exit 1
        fi
        
        # Buscar subredes públicas (con ruta a Internet Gateway)
        echo "Identificando subredes públicas en la VPC..."
        public_subnet_ids=()
        
        for subnet in "${all_subnets[@]}"; do
            # Verificar si la subred tiene una ruta a un Internet Gateway
            route_to_igw=$(aws ec2 describe-route-tables \
                --filters "Name=association.subnet-id,Values=$subnet" \
                --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
                --output text)
            
            if [[ $route_to_igw == *"igw-"* ]]; then
                public_subnet_ids+=("$subnet")
            fi
        done
        
        # Si no se encontraron subredes públicas, usar las primeras dos subredes como públicas y privadas
        if [ ${#public_subnet_ids[@]} -lt 2 ]; then
            echo "No se encontraron suficientes subredes públicas. Usando las primeras 2 subredes disponibles."
            public_subnet_1=${all_subnets[0]}
            public_subnet_2=${all_subnets[1]}
            private_subnet_1=${all_subnets[0]}
            private_subnet_2=${all_subnets[1]}
        else
            echo "Se encontraron ${#public_subnet_ids[@]} subredes públicas. Usando las primeras 2."
            public_subnet_1=${public_subnet_ids[0]}
            public_subnet_2=${public_subnet_ids[1]}
            # Preferir usar subredes diferentes para privadas si están disponibles
            if [ ${#all_subnets[@]} -gt 2 ]; then
                # Encontrar subredes que no sean públicas
                private_subnets=()
                for subnet in "${all_subnets[@]}"; do
                    if [[ ! " ${public_subnet_ids[@]} " =~ " ${subnet} " ]]; then
                        private_subnets+=("$subnet")
                    fi
                done
                
                if [ ${#private_subnets[@]} -ge 2 ]; then
                    private_subnet_1=${private_subnets[0]}
                    private_subnet_2=${private_subnets[1]}
                else
                    # Usar subredes públicas como privadas
                    private_subnet_1=${public_subnet_ids[0]}
                    private_subnet_2=${public_subnet_ids[1]}
                fi
            else
                # Usar subredes públicas como privadas
                private_subnet_1=${public_subnet_ids[0]}
                private_subnet_2=${public_subnet_ids[1]}
            fi
        fi
        
        echo "Usando subredes públicas: $public_subnet_1, $public_subnet_2"
        echo "Usando subredes privadas: $private_subnet_1, $private_subnet_2"
        
        # Establecer variables para uso posterior
        VPC_ID="$vpc_id"
        PUBLIC_SUBNET_IDS="$public_subnet_1,$public_subnet_2"
        PRIVATE_SUBNET_IDS="$private_subnet_1,$private_subnet_2"
        export VPC_ID PUBLIC_SUBNET_IDS PRIVATE_SUBNET_IDS
        
        # No marcar como VPC_CREATED ya que no fue creada por este script
        VPC_CREATED=false
    else
        echo "VPC creada: $vpc_id"
        
        # Esperar a que la VPC esté disponible
        aws ec2 wait vpc-available --vpc-ids "$vpc_id"
        
        # Habilitar nombres de DNS para la VPC
        aws ec2 modify-vpc-attribute \
            --vpc-id "$vpc_id" \
            --enable-dns-hostnames "{\"Value\":true}"
        
        # Crear Internet Gateway
        igw_id=$(aws ec2 create-internet-gateway \
            --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=terraform-test-igw}]" \
            --query "InternetGateway.InternetGatewayId" \
            --output text)
        
        echo "Internet Gateway creado: $igw_id"
        
        # Adjuntar Internet Gateway a la VPC
        aws ec2 attach-internet-gateway \
            --vpc-id "$vpc_id" \
            --internet-gateway-id "$igw_id"
        
        # Obtener las zonas de disponibilidad
        availability_zones=($(aws ec2 describe-availability-zones \
            --query "AvailabilityZones[0:2].ZoneName" \
            --output text))
        
        echo "Usando zonas de disponibilidad: ${availability_zones[0]} y ${availability_zones[1]}"
        
        # Crear subredes públicas
        public_subnet_1=$(aws ec2 create-subnet \
            --vpc-id "$vpc_id" \
            --cidr-block 10.0.1.0/24 \
            --availability-zone "${availability_zones[0]}" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=terraform-test-public-1}]" \
            --query "Subnet.SubnetId" \
            --output text)
        
        public_subnet_2=$(aws ec2 create-subnet \
            --vpc-id "$vpc_id" \
            --cidr-block 10.0.2.0/24 \
            --availability-zone "${availability_zones[1]}" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=terraform-test-public-2}]" \
            --query "Subnet.SubnetId" \
            --output text)
        
        echo "Subredes públicas creadas: $public_subnet_1, $public_subnet_2"
        
        # Habilitar asignación automática de IPs públicas en subredes públicas
        aws ec2 modify-subnet-attribute \
            --subnet-id "$public_subnet_1" \
            --map-public-ip-on-launch
        
        aws ec2 modify-subnet-attribute \
            --subnet-id "$public_subnet_2" \
            --map-public-ip-on-launch
        
        # Crear subredes privadas
        private_subnet_1=$(aws ec2 create-subnet \
            --vpc-id "$vpc_id" \
            --cidr-block 10.0.3.0/24 \
            --availability-zone "${availability_zones[0]}" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=terraform-test-private-1}]" \
            --query "Subnet.SubnetId" \
            --output text)
        
        private_subnet_2=$(aws ec2 create-subnet \
            --vpc-id "$vpc_id" \
            --cidr-block 10.0.4.0/24 \
            --availability-zone "${availability_zones[1]}" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=terraform-test-private-2}]" \
            --query "Subnet.SubnetId" \
            --output text)
        
        echo "Subredes privadas creadas: $private_subnet_1, $private_subnet_2"
        
        # Crear NAT Gateway para que las subredes privadas puedan acceder a Internet
        echo "Creando Elastic IP para NAT Gateway..."
        nat_eip=$(aws ec2 allocate-address \
            --domain vpc \
            --query "AllocationId" \
            --output text)
        
        echo "Elastic IP creada: $nat_eip"
        
        echo "Creando NAT Gateway..."
        nat_gateway_id=$(aws ec2 create-nat-gateway \
            --subnet-id "$public_subnet_1" \
            --allocation-id "$nat_eip" \
            --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=terraform-test-nat}]" \
            --query "NatGateway.NatGatewayId" \
            --output text)
        
        echo "NAT Gateway creado: $nat_gateway_id"
        
        # Esperar a que el NAT Gateway esté disponible
        echo "Esperando a que el NAT Gateway esté disponible..."
        aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat_gateway_id"
        
        # Crear tabla de enrutamiento para subredes públicas
        public_route_table=$(aws ec2 create-route-table \
            --vpc-id "$vpc_id" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=terraform-test-public-rt}]" \
            --query "RouteTable.RouteTableId" \
            --output text)
        
        echo "Tabla de enrutamiento pública creada: $public_route_table"
        
        # Crear ruta a Internet Gateway
        aws ec2 create-route \
            --route-table-id "$public_route_table" \
            --destination-cidr-block 0.0.0.0/0 \
            --gateway-id "$igw_id"
        
        # Asociar tabla de enrutamiento con subredes públicas
        aws ec2 associate-route-table \
            --subnet-id "$public_subnet_1" \
            --route-table-id "$public_route_table"
        
        aws ec2 associate-route-table \
            --subnet-id "$public_subnet_2" \
            --route-table-id "$public_route_table"
        
        # Crear tabla de enrutamiento para subredes privadas
        private_route_table=$(aws ec2 create-route-table \
            --vpc-id "$vpc_id" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=terraform-test-private-rt}]" \
            --query "RouteTable.RouteTableId" \
            --output text)
        
        echo "Tabla de enrutamiento privada creada: $private_route_table"
        
        # Crear ruta a NAT Gateway
        aws ec2 create-route \
            --route-table-id "$private_route_table" \
            --destination-cidr-block 0.0.0.0/0 \
            --nat-gateway-id "$nat_gateway_id"
        
        # Asociar tabla de enrutamiento con subredes privadas
        aws ec2 associate-route-table \
            --subnet-id "$private_subnet_1" \
            --route-table-id "$private_route_table"
        
        aws ec2 associate-route-table \
            --subnet-id "$private_subnet_2" \
            --route-table-id "$private_route_table"
        
        # Establecer variables para uso posterior
        VPC_ID="$vpc_id"
        PUBLIC_SUBNET_IDS="$public_subnet_1,$public_subnet_2"
        PRIVATE_SUBNET_IDS="$private_subnet_1,$private_subnet_2"
        export VPC_ID PUBLIC_SUBNET_IDS PRIVATE_SUBNET_IDS
        
        # Guardar IDs para el script de limpieza
        VPC_CREATED=true
        IGW_ID="$igw_id"
        NAT_GATEWAY_ID="$nat_gateway_id"
        NAT_EIP_ID="$nat_eip"
        PUBLIC_ROUTE_TABLE_ID="$public_route_table"
        PRIVATE_ROUTE_TABLE_ID="$private_route_table"
        
        echo "VPC y subredes creadas exitosamente"
    fi
}

# Verificar si las variables VPC_ID, PUBLIC_SUBNET_IDS, y PRIVATE_SUBNET_IDS están definidas
VPC_CREATED=false
if [ -z "$VPC_ID" ] || [ -z "$PUBLIC_SUBNET_IDS" ] || [ -z "$PRIVATE_SUBNET_IDS" ]; then
    create_vpc_and_subnets
else
    echo "Usando VPC y subredes existentes"
fi

# Convertir las listas de subredes en arrays
IFS=',' read -r -a public_subnets <<< "$PUBLIC_SUBNET_IDS"
IFS=',' read -r -a private_subnets <<< "$PRIVATE_SUBNET_IDS"

echo "Creando infraestructura en la región $AWS_REGION"
echo "VPC: $VPC_ID"
echo "Subredes públicas: ${public_subnets[*]}"
echo "Subredes privadas: ${private_subnets[*]}"

# Verificar si tenemos al menos 2 subredes públicas para el ALB
if [ ${#public_subnets[@]} -lt 2 ]; then
    echo "Advertencia: Se necesitan al menos 2 subredes públicas en diferentes zonas de disponibilidad para crear un ALB."
    echo "Intentando crear un servicio sin ALB..."
    
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
    
    # 3. Crear el Security Group para el servicio ECS
    echo "Creando Security Group para el servicio ECS..."
    ecs_sg_id=$(aws ec2 create-security-group \
        --group-name "test-ecs-sg-$(date +%s)" \
        --description "Security group for test ECS service" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)
    
    echo "Security Group del ECS creado: $ecs_sg_id"
    
    # Permitir tráfico HTTP entrante desde cualquier lugar (para pruebas)
    aws ec2 authorize-security-group-ingress \
        --group-id "$ecs_sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr "0.0.0.0/0"
    
    # 4. Crear el clúster ECS
    echo "Creando clúster ECS..."
    cluster_name="test-ecs-cluster-$(date +%s)"
    aws ecs create-cluster \
        --cluster-name "$cluster_name"
    
    echo "Clúster ECS creado: $cluster_name"
    
    # Verificar si terraform.tfvars ya existe, y eliminarlo
    if [ -f terraform.tfvars ]; then
        echo "Eliminando archivo terraform.tfvars existente..."
        rm terraform.tfvars
    fi
    
    # Generar archivo de variables para pruebas sin ALB
    cat > terraform.tfvars << EOF
cluster_name   = "${cluster_name}"
service_name   = "test-service"
docker_image   = "nginx:latest" # Usar una imagen pública para pruebas
container_port = 80
task_cpu       = "256"
task_memory    = "512"
subnet_ids     = [$(printf '"%s",' "${private_subnets[@]}" | sed 's/,$//')]
security_group_ids = ["${ecs_sg_id}"]
vpc_id         = "${VPC_ID}"

environment_variables = [
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

    # Script para limpiar los recursos
    cat > cleanup-test-infra.sh << EOF
#!/bin/bash
# Script para eliminar los recursos creados para pruebas

set -e

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

# Eliminar servicios ECS si existen
aws ecs list-services --cluster \$CLUSTER_NAME --query "serviceArns" --output text | tr '\t' '\n' | while read service; do
  if [ ! -z "\$service" ]; then
    echo "Eliminando servicio ECS: \$service"
    aws ecs update-service --cluster \$CLUSTER_NAME --service \$service --desired-count 0
    aws ecs delete-service --cluster \$CLUSTER_NAME --service \$service --force
  fi
done

# Esperar a que los servicios se eliminen
echo "Esperando a que los servicios se eliminen..."
sleep 30

# Eliminar clúster ECS
echo "Eliminando clúster ECS: \$CLUSTER_NAME"
aws ecs delete-cluster --cluster \$CLUSTER_NAME

# Eliminar security groups
echo "Eliminando security group de ECS: \$ECS_SG_ID"
aws ec2 delete-security-group --group-id \$ECS_SG_ID

# Eliminar la tabla DynamoDB
echo "Eliminando tabla DynamoDB: ${dynamodb_table}"
aws dynamodb delete-table --table-name "${dynamodb_table}" --region "${AWS_REGION}"

# Eliminar el bucket S3 (primero hay que vaciarlo)
echo "Vaciando y eliminando bucket S3: ${bucket_name}"
aws s3 rm "s3://${bucket_name}" --recursive
aws s3 rb "s3://${bucket_name}" --force

echo "Limpieza completada."
EOF

    chmod +x cleanup-test-infra.sh

    # Mostrar información sobre los recursos creados
    echo ""
    echo "=========================== INFRAESTRUCTURA CREADA ==========================="
    echo "Se ha creado la siguiente infraestructura para pruebas:"
    echo ""
    echo "Bucket S3 para backend: $bucket_name"
    echo "Tabla DynamoDB para bloqueos: $dynamodb_table"
    echo "Security Group ECS: $ecs_sg_id"
    echo "Clúster ECS: $cluster_name"
    echo ""
    echo "NOTA: No se ha creado un ALB porque no hay suficientes subredes públicas en diferentes zonas."
    echo "Se ha generado un archivo 'terraform.tfvars' con configuración para pruebas sin ALB."
    echo ""
    echo "Para usar el módulo, ejecuta:"
    echo "terraform init -reconfigure"
    echo "terraform plan"
    echo "terraform apply"
    echo ""
    echo "Para eliminar la infraestructura de prueba, ejecuta ./cleanup-test-infra.sh"
    echo "==========================================================================="

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
        --port 80 \
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

    # Verificar si terraform.tfvars ya existe, y eliminarlo
    if [ -f terraform.tfvars ]; then
        echo "Eliminando archivo terraform.tfvars existente..."
        rm terraform.tfvars
    fi
    
    # Generar el archivo terraform.tfvars para las pruebas
    cat > terraform.tfvars << EOF
cluster_name   = "${cluster_name}"
service_name   = "test-service"
docker_image   = "nginx:latest" # Usar una imagen pública para pruebas
container_port = 80
task_cpu       = "256"
task_memory    = "512"
subnet_ids     = [$(printf '"%s",' "${private_subnets[@]}" | sed 's/,$//')]
security_group_ids = ["${ecs_sg_id}"]
vpc_id         = "${VPC_ID}"
alb_listener_arn = "${listener_arn}"

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

    # Script para limpiar los recursos
    cat > cleanup-test-infra.sh << EOF
#!/bin/bash
# Script para eliminar los recursos creados para pruebas

set -e

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

# Eliminar servicios ECS si existen
aws ecs list-services --cluster \$CLUSTER_NAME --query "serviceArns" --output text | tr '\t' '\n' | while read service; do
  if [ ! -z "\$service" ]; then
    echo "Eliminando servicio ECS: \$service"
    aws ecs update-service --cluster \$CLUSTER_NAME --service \$service --desired-count 0
    aws ecs delete-service --cluster \$CLUSTER_NAME --service \$service --force
  fi
done

# Esperar a que los servicios se eliminen
echo "Esperando a que los servicios se eliminen..."
sleep 30

# Eliminar clúster ECS
echo "Eliminando clúster ECS: \$CLUSTER_NAME"
aws ecs delete-cluster --cluster \$CLUSTER_NAME

# Eliminar el listener
echo "Eliminando listener: \$ALB_LISTENER_ARN"
aws elbv2 delete-listener --listener-arn \$ALB_LISTENER_ARN

# Eliminar los target groups
echo "Eliminando target groups..."
aws elbv2 describe-target-groups --query "TargetGroups[?LoadBalancerArns[0]=='\$ALB_ARN'].TargetGroupArn" --output text | tr '\t' '\n' | while read tg; do
  echo "Eliminando target group: \$tg"
  aws elbv2 delete-target-group --target-group-arn \$tg
done

# Eliminar el ALB
echo "Eliminando ALB: \$ALB_ARN"
aws elbv2 delete-load-balancer --load-balancer-arn \$ALB_ARN

# Esperar a que el ALB se elimine
echo "Esperando a que el ALB se elimine..."
sleep 30

# Eliminar security groups
echo "Eliminando security group de ECS: \$ECS_SG_ID"
aws ec2 delete-security-group --group-id \$ECS_SG_ID

echo "Eliminando security group de ALB: ${alb_sg_id}"
aws ec2 delete-security-group --group-id "${alb_sg_id}"

echo "Eliminando la tabla DynamoDB: ${dynamodb_table}"
aws dynamodb delete-table --table-name "${dynamodb_table}" --region "${AWS_REGION}"

# Eliminar el bucket S3 (primero hay que vaciarlo)
echo "Vaciando y eliminando bucket S3: ${bucket_name}"
aws s3 rm "s3://${bucket_name}" --recursive
aws s3 rb "s3://${bucket_name}" --force

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
    echo "Se ha generado un archivo 'terraform.tfvars' con los valores para probar el módulo."
    echo "También se ha generado el archivo 'backend.tf' para usar el estado remoto."
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