# Terratest Tests

This directory contains comprehensive integration tests for the Terraform ECS WebApp module using [Terratest](https://terratest.gruntwork.io/).

## Overview

The tests create a complete AWS infrastructure environment, apply the module, verify all resources are created correctly, and then clean up everything. This ensures the module works end-to-end in a real AWS environment.

## Cleanup Orphaned Resources

If a test run fails or is interrupted, some AWS resources may be left behind. Use the cleanup script to remove them:

```bash
cd test
./cleanup-orphaned-resources.sh us-west-2  # Replace with your region
```

This script will remove:
- Secrets Manager secrets (`terratest-fixtures-db-password`)
- Application Load Balancers (`terratest-fixtures-alb`)
- Target Groups (`terratest-fixtures-default-tg`)
- CloudWatch Log Groups (`/ecs/terratest-fixtures-service`)
- ECS Services (any in `terratest-fixtures-cluster`)

**⚠️ Important**: Always run this script if you see errors about resources already existing when running tests.

## Prerequisites

- Go 1.21 or later
- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- AWS account with permissions to create:
  - VPC, Subnets, Internet Gateway, NAT Gateway
  - Application Load Balancer
  - ECS Cluster and Services
  - IAM Roles and Policies
  - Security Groups
  - CloudWatch Log Groups
  - Application Auto Scaling resources

## Running Tests

### Install Dependencies

```bash
go mod download
```

### Run All Tests

```bash
cd test
go test -v -timeout 60m
```

### Run Specific Test Suite

```bash
cd test
go test -v -timeout 60m -run TestTerraformModule/ECS_Service
```

### Run Tests in Parallel (Not Recommended)

By default, tests run sequentially to avoid resource name conflicts. If you want to run in parallel, ensure unique test names:

```bash
cd test
go test -v -timeout 60m -parallel 1
```

## Test Structure

```
test/
├── fixtures/              # Infrastructure base (VPC, ALB, ECS cluster)
│   ├── main.tf           # VPC, subnets, networking
│   ├── alb.tf            # Application Load Balancer
│   ├── ecs.tf            # ECS Cluster, CloudWatch Logs
│   └── outputs.tf        # Infrastructure outputs
├── terraform_test.go     # Main test orchestrator
├── ecs_service_test.go   # ECS service verification
├── target_group_test.go  # Target Group verification
├── autoscaling_test.go   # Auto Scaling verification
├── iam_test.go           # IAM roles verification
├── security_group_test.go # Security Groups verification
├── outputs_test.go       # Module outputs verification
└── helpers.go            # Helper functions
```

## Test Flow

1. **Setup Infrastructure**: Creates VPC, subnets, ALB, ECS cluster, etc.
2. **Apply Module**: Applies the Terraform module with test configuration
3. **Verify Resources**: Runs all test suites to verify resources
4. **Cleanup**: Destroys module resources, then infrastructure

## Configuration

Tests use environment variables for configuration:

- `AWS_DEFAULT_REGION` or `AWS_REGION`: AWS region (default: `us-east-1`)
- `ECR_REPOSITORY`: Docker image repository (default: `nginx`)
- `IMAGE_TAG`: Docker image tag (default: `latest`)
- `CONTAINER_PORT`: Container port (default: `80`)

## Test Coverage

The tests verify:

- ✅ ECS Service creation and configuration
- ✅ Task Definition with correct container settings
- ✅ Target Group configuration and health checks
- ✅ Auto Scaling policies (CPU-based)
- ✅ IAM Execution Role with correct policies
- ✅ Security Groups with proper ingress/egress rules
- ✅ All module outputs are valid

## Timeouts

Tests have a default timeout of 60 minutes to account for:
- Infrastructure creation (VPC, NAT Gateway, etc.)
- ECS service deployment and stabilization
- Resource verification

## Cost Considerations

⚠️ **Warning**: These tests create real AWS resources and will incur costs:
- VPC with NAT Gateway (~$0.045/hour)
- Application Load Balancer (~$0.0225/hour)
- ECS Fargate tasks (~$0.04/vCPU-hour + ~$0.004/GB-hour)
- Data transfer costs

Tests typically run for 10-20 minutes. Estimated cost per test run: **$0.10 - $0.50**

## CI/CD Integration

Tests are integrated into GitHub Actions workflow. See `.github/workflows/main.yaml` for configuration.

## Troubleshooting

### Tests Fail with "Resource Already Exists"

- Ensure previous test runs completed cleanup
- Check for orphaned resources in AWS console
- Use unique test names if running multiple tests simultaneously

### Tests Timeout

- Increase timeout: `go test -timeout 90m`
- Check AWS service limits in your account
- Verify network connectivity to AWS

### Permission Errors

- Ensure AWS credentials have sufficient permissions
- Check IAM policies for required actions
- Verify region is correct and accessible

## Contributing

When adding new tests:

1. Follow the existing test structure
2. Use helper functions from `helpers.go`
3. Add appropriate assertions with clear error messages
4. Ensure tests clean up resources properly
5. Update this README if adding new test categories
