#!/bin/bash
set -e

# Script para limpiar recursos huérfanos de Terratest
# Uso: ./cleanup-orphaned-resources.sh [region]

REGION="${1:-us-west-2}"
echo "🧹 Limpiando recursos huérfanos de Terratest en región: $REGION"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para imprimir con color
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# 1. Eliminar secreto de Secrets Manager
echo ""
echo "📦 Limpiando Secrets Manager..."
SECRET_NAME="terratest-fixtures-db-password"
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
    echo "   Encontrado: $SECRET_NAME"
    aws secretsmanager delete-secret \
        --secret-id "$SECRET_NAME" \
        --force-delete-without-recovery \
        --region "$REGION" &>/dev/null || true
    print_status "Secreto eliminado: $SECRET_NAME"
else
    print_warning "Secreto no encontrado: $SECRET_NAME (ya fue eliminado)"
fi

# 2. Eliminar ALB y Target Groups
echo ""
echo "🔄 Limpiando Application Load Balancer..."
ALB_NAME="terratest-fixtures-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?LoadBalancerName=='$ALB_NAME'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

if [ -n "$ALB_ARN" ]; then
    echo "   Encontrado ALB: $ALB_NAME"
    
    # Eliminar listeners primero
    LISTENER_ARNS=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --region "$REGION" \
        --query "Listeners[].ListenerArn" \
        --output text 2>/dev/null || echo "")
    
    for LISTENER_ARN in $LISTENER_ARNS; do
        aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" --region "$REGION" &>/dev/null || true
        print_status "Listener eliminado"
    done
    
    # Eliminar ALB
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" &>/dev/null || true
    print_status "ALB eliminado: $ALB_NAME"
    
    # Esperar a que se elimine
    echo "   Esperando a que el ALB se elimine completamente..."
    sleep 10
else
    print_warning "ALB no encontrado: $ALB_NAME (ya fue eliminado)"
fi

# 3. Eliminar Target Group
echo ""
echo "🎯 Limpiando Target Groups..."
TG_NAME="terratest-fixtures-default-tg"
TG_ARN=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?TargetGroupName=='$TG_NAME'].TargetGroupArn" \
    --output text 2>/dev/null || echo "")

if [ -n "$TG_ARN" ]; then
    echo "   Encontrado Target Group: $TG_NAME"
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" &>/dev/null || true
    print_status "Target Group eliminado: $TG_NAME"
else
    print_warning "Target Group no encontrado: $TG_NAME (ya fue eliminado)"
fi

# 4. Eliminar CloudWatch Log Group
echo ""
echo "📊 Limpiando CloudWatch Log Groups..."
LOG_GROUP="/ecs/terratest-fixtures-service"
if aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --region "$REGION" \
    --query "logGroups[?logGroupName=='$LOG_GROUP']" \
    --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
    echo "   Encontrado Log Group: $LOG_GROUP"
    aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION" &>/dev/null || true
    print_status "Log Group eliminado: $LOG_GROUP"
else
    print_warning "Log Group no encontrado: $LOG_GROUP (ya fue eliminado)"
fi

# 5. Buscar y eliminar otros recursos con el tag ManagedBy=terratest
echo ""
echo "🔍 Buscando otros recursos huérfanos con tag ManagedBy=terratest..."

# Eliminar ECS Services huérfanos
echo ""
echo "🐳 Limpiando ECS Services..."
ECS_SERVICES=$(aws ecs list-services \
    --cluster "terratest-fixtures-cluster" \
    --region "$REGION" \
    --query "serviceArns[]" \
    --output text 2>/dev/null || echo "")

if [ -n "$ECS_SERVICES" ]; then
    for SERVICE_ARN in $ECS_SERVICES; do
        SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
        echo "   Encontrado servicio: $SERVICE_NAME"
        # Escalar a 0 primero
        aws ecs update-service \
            --cluster "terratest-fixtures-cluster" \
            --service "$SERVICE_NAME" \
            --desired-count 0 \
            --region "$REGION" &>/dev/null || true
        # Eliminar servicio
        aws ecs delete-service \
            --cluster "terratest-fixtures-cluster" \
            --service "$SERVICE_NAME" \
            --force \
            --region "$REGION" &>/dev/null || true
        print_status "Servicio ECS eliminado: $SERVICE_NAME"
    done
else
    print_warning "No se encontraron servicios ECS huérfanos"
fi

echo ""
echo -e "${GREEN}✅ Limpieza completada!${NC}"
echo ""
echo "Nota: Algunos recursos pueden tardar unos minutos en eliminarse completamente."
echo "Si el script falla, espera unos minutos y ejecútalo nuevamente."
