package test

import (
	"fmt"
	"math/rand"
	"os"
	"strings"
	"testing"
	"time"

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

	terraformOptions := &terraform.Options{
		TerraformDir:    fixturesDir,
		TerraformBinary: "terraform",
		Vars: map[string]interface{}{
			"test_name":  testName,
			"aws_region": awsRegion,
		},
		NoColor: true,
	}

	t.Logf("📦 Initializing and applying infrastructure fixtures...")
	terraform.InitAndApply(t, terraformOptions)
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
	terraform.Destroy(t, terraformOptions)
	t.Logf("✅ Infrastructure fixtures destroyed")
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
