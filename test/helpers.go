package test

import (
	"fmt"
	"math/rand"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/dynamodb"
	"github.com/aws/aws-sdk-go/service/s3"
	terratestaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
)

// InfrastructureOutputs contains outputs from the infrastructure fixtures
type InfrastructureOutputs struct {
	VPCID                  string
	PrivateSubnetIDs       []string
	PublicSubnetIDs        []string
	ALBListenerARN         string
	ALBSecurityGroupID     string
	ClusterName            string
	CloudWatchLogGroupName string
	AWSRegion              string
	TestSecretARN          string
	APIKeyARN              string
}

// setupInfrastructure applies the infrastructure fixtures and returns outputs
func setupInfrastructure(t *testing.T, testName string) (*terraform.Options, *InfrastructureOutputs) {
	fixturesDir := "../test/fixtures"
	awsRegion := getAWSRegion()

	t.Logf("🏗️  Setting up infrastructure base...")
	t.Logf("   Test Name: %s", testName)
	t.Logf("   AWS Region: %s", awsRegion)
	t.Logf("   Fixtures Directory: %s", fixturesDir)

	// Get AWS account ID for bucket name
	awsAccountID := getAWSAccountID(t, awsRegion)
	bucketName := fmt.Sprintf("terraform-ecs-webapp-test-%s-%s", awsRegion, awsAccountID)
	dynamoTableName := "terraform-ecs-webapp-test-locks"

	t.Logf("   State Bucket: %s", bucketName)
	t.Logf("   Lock Table: %s", dynamoTableName)

	// Step 1: Bootstrap S3 bucket and DynamoDB table (without backend)
	// Create bootstrap resources first, then migrate state to backend
	t.Logf("🔧 Bootstrapping backend resources (S3 bucket and DynamoDB table)...")
	bootstrapOptions := &terraform.Options{
		TerraformDir:    fixturesDir,
		TerraformBinary: "terraform",
		// No BackendConfig means Terraform will use local state
		Vars: map[string]interface{}{
			"aws_region": awsRegion,
		},
		NoColor: true,
		Targets: []string{
			"aws_s3_bucket.terraform_state",
			"aws_s3_bucket_versioning.terraform_state",
			"aws_s3_bucket_server_side_encryption_configuration.terraform_state",
			"aws_s3_bucket_public_access_block.terraform_state",
			"aws_dynamodb_table.terraform_locks",
		},
	}

	// Initialize without backend and apply bootstrap resources
	terraform.Init(t, bootstrapOptions)

	// Check if S3 bucket already exists (it's shared across all tests)
	bucketExists := checkS3BucketExists(t, awsRegion, bucketName)
	if bucketExists {
		t.Logf("   S3 bucket '%s' already exists, importing to state...", bucketName)
		// Import the existing bucket into Terraform state to avoid creation errors
		// Use -var flags to pass variables and -input=false to avoid interactive prompts
		importArgs := []string{
			"import",
			"-input=false",
			"-var", fmt.Sprintf("aws_region=%s", awsRegion),
			"aws_s3_bucket.terraform_state",
			bucketName,
		}
		_, importErr := terraform.RunTerraformCommandE(t, bootstrapOptions, importArgs...)
		if importErr != nil {
			t.Logf("   ⚠️  Could not import S3 bucket (may already be in state): %v", importErr)
		} else {
			t.Logf("   ✅ S3 bucket imported to state")
		}
	}

	// Check if DynamoDB table already exists (it's shared across all tests)
	tableExists := checkDynamoDBTableExists(t, awsRegion, dynamoTableName)
	if tableExists {
		t.Logf("   DynamoDB table '%s' already exists, importing to state...", dynamoTableName)
		// Import the existing table into Terraform state to avoid creation errors
		// Use -var flags to pass variables and -input=false to avoid interactive prompts
		importArgs := []string{
			"import",
			"-input=false",
			"-var", fmt.Sprintf("aws_region=%s", awsRegion),
			"aws_dynamodb_table.terraform_locks",
			dynamoTableName,
		}
		_, importErr := terraform.RunTerraformCommandE(t, bootstrapOptions, importArgs...)
		if importErr != nil {
			t.Logf("   ⚠️  Could not import DynamoDB table (may already be in state): %v", importErr)
		} else {
			t.Logf("   ✅ DynamoDB table imported to state")
		}
	}

	// Use ApplyE to handle errors gracefully (e.g., S3 bucket already exists)
	// The DynamoDB table is shared across all tests, so it may already exist
	_, err := terraform.ApplyE(t, bootstrapOptions)
	if err != nil {
		// Check if error is due to resource already existing
		errStr := err.Error()
		if strings.Contains(errStr, "already exists") ||
			strings.Contains(errStr, "ResourceInUseException") ||
			strings.Contains(errStr, "TableAlreadyExistsException") ||
			strings.Contains(errStr, "BucketAlreadyOwnedByYou") ||
			strings.Contains(errStr, "BucketAlreadyExists") {
			t.Logf("⚠️  Some bootstrap resources already exist, this is expected")
			t.Logf("   DynamoDB table and S3 bucket are shared resources")
			t.Logf("   Continuing with existing resources...")
		} else {
			// For other errors, fail the test
			t.Fatalf("Failed to apply bootstrap resources: %v", err)
		}
	} else {
		t.Logf("✅ Bootstrap resources created successfully")
	}
	t.Logf("✅ Backend resources ready")

	// Step 2: Now initialize with backend and apply the rest
	terraformOptions := &terraform.Options{
		TerraformDir:    fixturesDir,
		TerraformBinary: "terraform",
		BackendConfig: map[string]interface{}{
			"bucket":         bucketName,
			"key":            "fixtures/terraform.tfstate",
			"region":         awsRegion,
			"dynamodb_table": dynamoTableName,
			"encrypt":        true,
		},
		Vars: map[string]interface{}{
			"aws_region": awsRegion,
		},
		NoColor: true,
	}

	t.Logf("📦 Initializing with backend and applying infrastructure fixtures...")
	terraform.Init(t, terraformOptions)
	terraform.Apply(t, terraformOptions)
	t.Logf("✅ Infrastructure fixtures applied successfully")

	t.Logf("📤 Reading infrastructure outputs...")
	outputs := &InfrastructureOutputs{
		VPCID:                  terraform.Output(t, terraformOptions, "vpc_id"),
		PrivateSubnetIDs:       terraform.OutputList(t, terraformOptions, "private_subnet_ids"),
		PublicSubnetIDs:        terraform.OutputList(t, terraformOptions, "public_subnet_ids"),
		ALBListenerARN:         terraform.Output(t, terraformOptions, "alb_listener_arn"),
		ALBSecurityGroupID:     terraform.Output(t, terraformOptions, "alb_security_group_id"),
		ClusterName:            terraform.Output(t, terraformOptions, "cluster_name"),
		CloudWatchLogGroupName: terraform.Output(t, terraformOptions, "cloudwatch_log_group_name"),
		AWSRegion:              terraform.Output(t, terraformOptions, "aws_region"),
		TestSecretARN:          terraform.Output(t, terraformOptions, "test_secret_arn"),
		APIKeyARN:              terraform.Output(t, terraformOptions, "api_key_arn"),
	}

	t.Logf("✅ Infrastructure outputs retrieved:")
	t.Logf("   VPC ID: %s", outputs.VPCID)
	t.Logf("   Private Subnets: %v", outputs.PrivateSubnetIDs)
	t.Logf("   ALB Listener ARN: %s", outputs.ALBListenerARN)
	t.Logf("   ALB Security Group ID: %s", outputs.ALBSecurityGroupID)
	t.Logf("   Cluster Name: %s", outputs.ClusterName)
	t.Logf("   Log Group Name: %s", outputs.CloudWatchLogGroupName)
	t.Logf("   Test Secret ARN: %s", outputs.TestSecretARN)
	t.Logf("   API Key ARN: %s", outputs.APIKeyARN)

	return terraformOptions, outputs
}

// teardownInfrastructure destroys the infrastructure fixtures
func teardownInfrastructure(t *testing.T, terraformOptions *terraform.Options) {
	t.Logf("🧹 Tearing down infrastructure fixtures...")

	// Use DestroyE to handle errors gracefully
	// This allows cleanup to continue even if there are issues
	_, err := terraform.DestroyE(t, terraformOptions)
	if err != nil {
		// If the error is because resources don't exist, treat it as success
		if isResourceNotFoundError(err) {
			t.Logf("✅ Resources already destroyed or not found (this is expected)")
			t.Logf("   Error details: %v", err)
		} else {
			t.Logf("⚠️  Warning: Error during infrastructure teardown: %v", err)
			t.Logf("   Resources may need manual cleanup")
			if bucket, ok := terraformOptions.BackendConfig["bucket"].(string); ok {
				t.Logf("   State bucket: %s", bucket)
			}
		}
	} else {
		t.Logf("✅ Infrastructure fixtures destroyed")
	}
}

// cleanupModule destroys the module resources
func cleanupModule(t *testing.T, terraformOptions *terraform.Options) {
	t.Logf("🧹 Tearing down module resources...")

	// Use DestroyE to handle errors gracefully
	_, err := terraform.DestroyE(t, terraformOptions)
	if err != nil {
		// If the error is because resources don't exist, treat it as success
		if isResourceNotFoundError(err) {
			t.Logf("✅ Resources already destroyed or not found (this is expected)")
			t.Logf("   Error details: %v", err)
		} else {
			t.Logf("⚠️  Warning: Error during module teardown: %v", err)
			t.Logf("   Resources may need manual cleanup")
		}
	} else {
		t.Logf("✅ Module resources destroyed")
	}
}

// setupModuleOptions configures Terraform options for the module
func setupModuleOptions(t *testing.T, moduleDir string, outputs *InfrastructureOutputs, testName string) *terraform.Options {
	// Use a simple Docker image for testing (nginx)
	dockerImage := "nginx"
	imageTag := "latest"

	// Check if ECR_REPOSITORY is set (for custom images)
	if ecrRepo := os.Getenv("ECR_REPOSITORY"); ecrRepo != "" {
		dockerImage = ecrRepo
	}
	if tag := os.Getenv("IMAGE_TAG"); tag != "" {
		imageTag = tag
	}

	containerPort := 80
	if port := os.Getenv("CONTAINER_PORT"); port != "" {
		fmt.Sscanf(port, "%d", &containerPort)
	} else {
		containerPort = 80
	}

	return &terraform.Options{
		TerraformDir:    moduleDir,
		TerraformBinary: "terraform",
		Vars: map[string]interface{}{
			"cluster_name":              outputs.ClusterName,
			"service_name":              fmt.Sprintf("%s-service", testName),
			"docker_image":              dockerImage,
			"image_tag":                 imageTag,
			"container_port":            containerPort,
			"task_cpu":                  "256",
			"task_memory":               "512",
			"subnet_ids":                outputs.PrivateSubnetIDs,
			"vpc_id":                    outputs.VPCID,
			"alb_listener_arn":          outputs.ALBListenerARN,
			"alb_security_group_id":     outputs.ALBSecurityGroupID,
			"cloudwatch_log_group_name": outputs.CloudWatchLogGroupName,
			"secret_variables": []map[string]interface{}{
				{
					"name":      "TEST_SECRET",
					"valueFrom": outputs.TestSecretARN,
				},
				{
					"name":      "API_KEY",
					"valueFrom": outputs.APIKeyARN,
				},
			},
			"health_check": map[string]interface{}{
				"path":                "/",
				"interval":            30,
				"timeout":             5,
				"healthy_threshold":   2,
				"unhealthy_threshold": 2,
				"matcher":             "200-399",
			},
			"autoscaling_config": map[string]interface{}{
				"min_capacity": 1,
				"max_capacity": 2,
				"cpu": map[string]interface{}{
					"target_value":       50,
					"scale_in_cooldown":  60,
					"scale_out_cooldown": 60,
				},
			},
			"deployment_config": map[string]interface{}{
				"maximum_percent":         200,
				"minimum_healthy_percent": 100,
			},
			"common_tags": map[string]interface{}{
				"Project":     "terratest",
				"Environment": "test",
				"TestName":    testName,
			},
		},
		NoColor:            true,
		MaxRetries:         3,
		TimeBetweenRetries: 5 * time.Second,
		RetryableTerraformErrors: map[string]string{
			"RequestError": "Temporary AWS API error",
		},
	}
}

// getRandomName generates a unique name for test resources
func getRandomName(prefix string) string {
	rand.Seed(time.Now().UnixNano())
	suffix := rand.Intn(10000)
	return fmt.Sprintf("%s-%d", prefix, suffix)
}

// getAWSRegion gets the AWS region from environment or defaults to us-east-1
func getAWSRegion() string {
	region := os.Getenv("AWS_DEFAULT_REGION")
	if region == "" {
		region = os.Getenv("AWS_REGION")
	}
	if region == "" {
		region = "us-east-1"
	}
	return region
}

// sanitizeName ensures the name is valid for AWS resources
func sanitizeName(name string) string {
	// AWS resource names can only contain alphanumeric characters and hyphens
	name = strings.ToLower(name)
	name = strings.ReplaceAll(name, "_", "-")
	// Remove any invalid characters
	var result strings.Builder
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			result.WriteRune(r)
		}
	}
	return result.String()
}

// getAWSAccountID gets the AWS account ID from the current AWS credentials
func getAWSAccountID(t *testing.T, region string) string {
	// Use Terratest AWS module to get caller identity
	accountID := terratestaws.GetAccountId(t)
	return accountID
}

// checkDynamoDBTableExists checks if a DynamoDB table exists
func checkDynamoDBTableExists(t *testing.T, region, tableName string) bool {
	dynamoClient := terratestaws.NewDynamoDBClient(t, region)

	// Try to describe the table
	_, err := dynamoClient.DescribeTable(&dynamodb.DescribeTableInput{
		TableName: aws.String(tableName),
	})

	return err == nil
}

// checkS3BucketExists checks if an S3 bucket exists
func checkS3BucketExists(t *testing.T, region, bucketName string) bool {
	s3Client := terratestaws.NewS3Client(t, region)

	// Try to head the bucket (lightweight operation to check existence)
	_, err := s3Client.HeadBucket(&s3.HeadBucketInput{
		Bucket: aws.String(bucketName),
	})

	return err == nil
}

// isResourceNotFoundError checks if an error indicates that a resource was not found
// This is useful for treating "resource not found" errors as success during destroy operations
func isResourceNotFoundError(err error) bool {
	if err == nil {
		return false
	}
	errStr := strings.ToLower(err.Error())
	notFoundPatterns := []string{
		"does not exist",
		"not found",
		"resourcenotfoundexception",
		"nosuchentity",
		"invalidparametervalue: resource",
		"does not exist in state",
		"no such",
		"cannot find",
		"not exist",
	}
	for _, pattern := range notFoundPatterns {
		if strings.Contains(errStr, pattern) {
			return true
		}
	}
	return false
}
