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
	ALBLoadBalancerARN     string   // Optional - empty if ALB is not configured
	ALBSecurityGroupID     string   // Optional - empty if ALB is not configured
	ServiceDiscoveryNSID   string   // Optional - namespace ID for service discovery
	ClusterName            string
	CloudWatchLogGroupName string
	AWSRegion              string
	TestSecretARN          string
	APIKeyARN              string
}

// setupInfrastructure applies the infrastructure fixtures and returns outputs
// Returns (options, outputs, error) - options is always returned so cleanup can run even if there are errors
func setupInfrastructure(t *testing.T, testName string) (*terraform.Options, *InfrastructureOutputs, error) {
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

	// Create the main terraform options FIRST so we can return them for cleanup even if init fails
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
	// Use InitE to handle errors gracefully - we want to return options for cleanup even if init fails
	if _, err := terraform.InitE(t, bootstrapOptions); err != nil {
		t.Logf("❌ Error initializing bootstrap: %v", err)
		return terraformOptions, nil, fmt.Errorf("failed to initialize bootstrap: %w", err)
	}

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
		errStr := strings.ToLower(err.Error())
		if strings.Contains(errStr, "already exists") ||
			strings.Contains(errStr, "resourceinuseexception") ||
			strings.Contains(errStr, "tablealreadyexistsexception") ||
			strings.Contains(errStr, "bucketalreadyownedbyyou") ||
			strings.Contains(errStr, "bucketalreadyexists") {
			t.Logf("⚠️  Some bootstrap resources already exist, this is expected")
			t.Logf("   DynamoDB table and S3 bucket are shared resources")
			t.Logf("   Continuing with existing resources...")
		} else {
			// Log error but don't fail immediately - cleanup needs to run
			t.Logf("⚠️  Error applying bootstrap resources: %v", err)
			t.Logf("   Continuing anyway - cleanup will handle any partial resources")
		}
	} else {
		t.Logf("✅ Bootstrap resources created successfully")
	}
	t.Logf("✅ Backend resources ready")

	// Step 2: Now initialize with backend and apply the rest
	t.Logf("📦 Initializing with backend and applying infrastructure fixtures...")
	// Use InitE to handle errors gracefully - we want to return options for cleanup even if init fails
	if _, err := terraform.InitE(t, terraformOptions); err != nil {
		t.Logf("❌ Error initializing with backend: %v", err)
		return terraformOptions, nil, fmt.Errorf("failed to initialize with backend: %w", err)
	}

	// Use ApplyE to handle errors gracefully - this allows cleanup to execute even if apply fails
	_, err = terraform.ApplyE(t, terraformOptions)
	if err != nil {
		// Log the error but don't fail immediately - cleanup will handle it
		errStr := strings.ToLower(err.Error())
		if strings.Contains(errStr, "already exists") ||
			strings.Contains(errStr, "parameteralreadyexists") ||
			strings.Contains(errStr, "resourceinuseexception") ||
			strings.Contains(errStr, "accessdenied") ||
			strings.Contains(errStr, "unauthorizedoperation") {
			t.Logf("⚠️  Error applying infrastructure fixtures: %v", err)
			t.Logf("   This may be due to existing resources or permissions")
			t.Logf("   Cleanup will attempt to destroy what was created")
		} else {
			t.Logf("❌ Fatal error applying infrastructure fixtures: %v", err)
			t.Logf("   Cleanup will attempt to destroy what was created")
			// Don't use t.Fatalf here - let cleanup execute
			// The test will fail naturally if outputs can't be read
		}
	} else {
		t.Logf("✅ Infrastructure fixtures applied successfully")
	}

	t.Logf("📤 Reading infrastructure outputs...")
	// Try to read outputs even if apply failed - some resources may have been created
	// Use OutputE to handle errors gracefully - read each output individually
	outputs := &InfrastructureOutputs{
		AWSRegion: awsRegion,
	}

	// Try to read each output, but don't fail if any are missing
	if vpcID, err := terraform.OutputE(t, terraformOptions, "vpc_id"); err == nil {
		outputs.VPCID = vpcID
	} else {
		t.Logf("⚠️  Could not read vpc_id output: %v", err)
	}

	if privateSubnets, err := terraform.OutputListE(t, terraformOptions, "private_subnet_ids"); err == nil {
		outputs.PrivateSubnetIDs = privateSubnets
	} else {
		t.Logf("⚠️  Could not read private_subnet_ids output: %v", err)
	}

	if publicSubnets, err := terraform.OutputListE(t, terraformOptions, "public_subnet_ids"); err == nil {
		outputs.PublicSubnetIDs = publicSubnets
	} else {
		t.Logf("⚠️  Could not read public_subnet_ids output: %v", err)
	}

	if albLoadBalancerARN, err := terraform.OutputE(t, terraformOptions, "alb_load_balancer_arn"); err == nil {
		outputs.ALBLoadBalancerARN = albLoadBalancerARN
	} else {
		t.Logf("⚠️  Could not read alb_load_balancer_arn output: %v", err)
	}

	if albSGID, err := terraform.OutputE(t, terraformOptions, "alb_security_group_id"); err == nil {
		outputs.ALBSecurityGroupID = albSGID
	} else {
		t.Logf("⚠️  Could not read alb_security_group_id output: %v", err)
	}

	if clusterName, err := terraform.OutputE(t, terraformOptions, "cluster_name"); err == nil {
		outputs.ClusterName = clusterName
	} else {
		t.Logf("⚠️  Could not read cluster_name output: %v", err)
	}

	if logGroupName, err := terraform.OutputE(t, terraformOptions, "cloudwatch_log_group_name"); err == nil {
		outputs.CloudWatchLogGroupName = logGroupName
	} else {
		t.Logf("⚠️  Could not read cloudwatch_log_group_name output: %v", err)
	}

	if testSecretARN, err := terraform.OutputE(t, terraformOptions, "test_secret_arn"); err == nil {
		outputs.TestSecretARN = testSecretARN
	} else {
		t.Logf("⚠️  Could not read test_secret_arn output: %v", err)
	}

	if apiKeyARN, err := terraform.OutputE(t, terraformOptions, "api_key_arn"); err == nil {
		outputs.APIKeyARN = apiKeyARN
	} else {
		t.Logf("⚠️  Could not read api_key_arn output: %v", err)
	}

	t.Logf("✅ Infrastructure outputs retrieved:")
	// Helper function to format output values, showing "(not available)" if empty
	formatOutput := func(value string) string {
		if value == "" {
			return "(not available)"
		}
		return value
	}

	t.Logf("   VPC ID: %s", formatOutput(outputs.VPCID))
	if len(outputs.PrivateSubnetIDs) > 0 {
		t.Logf("   Private Subnets: %v", outputs.PrivateSubnetIDs)
	} else {
		t.Logf("   Private Subnets: (not available)")
	}
	if len(outputs.PublicSubnetIDs) > 0 {
		t.Logf("   Public Subnets: %v", outputs.PublicSubnetIDs)
	} else {
		t.Logf("   Public Subnets: (not available)")
	}
	t.Logf("   ALB Load Balancer ARN: %s", formatOutput(outputs.ALBLoadBalancerARN))
	t.Logf("   ALB Security Group ID: %s", formatOutput(outputs.ALBSecurityGroupID))
	t.Logf("   Cluster Name: %s", formatOutput(outputs.ClusterName))
	t.Logf("   Log Group Name: %s", formatOutput(outputs.CloudWatchLogGroupName))
	t.Logf("   Test Secret ARN: %s", formatOutput(outputs.TestSecretARN))
	t.Logf("   API Key ARN: %s", formatOutput(outputs.APIKeyARN))

	// Validate that critical outputs are present before continuing
	validateInfrastructureOutputs(t, outputs)

	return terraformOptions, outputs, nil
}

// validateInfrastructureOutputs validates that critical infrastructure outputs are present
// This prevents Terraform from failing later with invalid values like empty strings
func validateInfrastructureOutputs(t *testing.T, outputs *InfrastructureOutputs) {
	var missingOutputs []string

	if outputs.VPCID == "" {
		missingOutputs = append(missingOutputs, "vpc_id")
	}
	if len(outputs.PrivateSubnetIDs) == 0 {
		missingOutputs = append(missingOutputs, "private_subnet_ids")
	}
	// ALB outputs are optional - only validate if they're being used
	// (This will be determined by the test configuration)
	if outputs.ClusterName == "" {
		missingOutputs = append(missingOutputs, "cluster_name")
	}
	if outputs.CloudWatchLogGroupName == "" {
		missingOutputs = append(missingOutputs, "cloudwatch_log_group_name")
	}
	if outputs.TestSecretARN == "" {
		missingOutputs = append(missingOutputs, "test_secret_arn")
	}
	if outputs.APIKeyARN == "" {
		missingOutputs = append(missingOutputs, "api_key_arn")
	}

	if len(missingOutputs) > 0 {
		t.Errorf("❌ Critical infrastructure outputs are missing: %v", missingOutputs)
		t.Errorf("   This usually means the infrastructure fixtures failed to apply correctly")
		t.Errorf("   Check the logs above for errors during terraform apply")
		t.Errorf("   Cleanup will still execute to remove any partially created resources")
		// Don't use t.Fatalf here - allow cleanup to execute
		// The test will fail naturally when Terraform tries to use invalid values
	}

	// Validate that either ALB or Service Discovery is available (required by the module)
	if outputs.ALBLoadBalancerARN == "" && outputs.ServiceDiscoveryNSID == "" {
		t.Errorf("❌ Neither ALB nor Service Discovery is available")
		t.Errorf("   The module requires at least one of: alb_load_balancer_arn or service_discovery")
		t.Errorf("   Current fixtures create ALB by default - check if ALB creation failed")
	}
}

// teardownInfrastructure destroys the infrastructure fixtures
func teardownInfrastructure(t *testing.T, terraformOptions *terraform.Options) {
	t.Logf("🧹 Tearing down infrastructure fixtures...")

	// Handle nil options gracefully
	if terraformOptions == nil {
		t.Logf("⚠️  No terraform options provided, skipping infrastructure teardown")
		return
	}

	// Use DestroyE to handle errors gracefully
	// This allows cleanup to continue even if there are issues
	_, err := terraform.DestroyE(t, terraformOptions)
	if err != nil {
		// If the error is because resources don't exist, treat it as success
		if isResourceNotFoundError(err) {
			t.Logf("✅ Resources already destroyed or not found (this is expected)")
			t.Logf("   Error details: %v", err)
		} else if isBucketNotEmptyError(err) {
			// BucketNotEmpty is expected - the bucket is shared and may contain state from other tests
			// With force_destroy=true, Terraform should handle this, but if it doesn't, it's not critical
			t.Logf("⚠️  Warning: S3 bucket could not be deleted (may contain state from other tests)")
			t.Logf("   This is expected for shared test infrastructure")
			t.Logf("   The bucket will be reused in future test runs")
			if bucket, ok := terraformOptions.BackendConfig["bucket"].(string); ok {
				t.Logf("   State bucket: %s", bucket)
			}
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

	// Handle nil options gracefully
	if terraformOptions == nil {
		t.Logf("⚠️  No terraform options provided, skipping module teardown")
		return
	}

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

	vars := map[string]interface{}{
		"cluster_name":              outputs.ClusterName,
		"service_name":              fmt.Sprintf("%s-service", testName),
		"docker_image":              dockerImage,
		"image_tag":                 imageTag,
		"container_port":           containerPort,
		"task_cpu":                 "256",
		"task_memory":              "512",
		"subnet_ids":               outputs.PrivateSubnetIDs,
		"vpc_id":                   outputs.VPCID,
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
	}

	// Add ALB-related variables only if ALB is configured
	if outputs.ALBLoadBalancerARN != "" && outputs.ALBSecurityGroupID != "" {
		vars["alb_load_balancer_arn"] = outputs.ALBLoadBalancerARN
		vars["alb_security_group_id"] = outputs.ALBSecurityGroupID
		vars["health_check"] = map[string]interface{}{
			"path":                "/",
			"interval":            30,
			"timeout":             5,
			"healthy_threshold":   2,
			"unhealthy_threshold": 2,
			"matcher":             "200-399",
		}
		vars["listener_rules"] = []map[string]interface{}{
			{
				"priority":      100,
				"path_patterns": []string{"/*"},
			},
		}
	} else if outputs.ServiceDiscoveryNSID != "" {
		// When ALB is not configured, service_discovery is required
		vars["service_discovery"] = map[string]interface{}{
			"namespace_id": outputs.ServiceDiscoveryNSID,
			"dns": map[string]interface{}{
				"name": fmt.Sprintf("%s-service", testName),
				"type": "A",
				"ttl":  60,
			},
		}
	}

	return &terraform.Options{
		TerraformDir:    moduleDir,
		TerraformBinary: "terraform",
		Vars:            vars,
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

// isBucketNotEmptyError checks if an error indicates that an S3 bucket cannot be deleted because it's not empty
// This is useful for treating "bucket not empty" errors as a non-fatal warning during cleanup
// The bucket is shared across tests and may contain state from other test runs
func isBucketNotEmptyError(err error) bool {
	if err == nil {
		return false
	}
	errStr := strings.ToLower(err.Error())
	return strings.Contains(errStr, "bucketnotempty") ||
		strings.Contains(errStr, "bucket is not empty") ||
		strings.Contains(errStr, "you must delete all versions")
}
