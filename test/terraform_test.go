package test

import (
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/terraform"
)

func TestTerraformModule(t *testing.T) {
	t.Parallel()

	// Generate unique test name
	testName := sanitizeName(getRandomName("terratest"))

	// Setup infrastructure fixtures
	infraOptions, infraOutputs := setupInfrastructure(t, testName)
	defer teardownInfrastructure(t, infraOptions)

	// Setup module options
	moduleOptions := setupModuleOptions(t, "..", infraOutputs, testName)

	// Cleanup module resources
	defer terraform.Destroy(t, moduleOptions)

	// Apply module
	t.Logf("🚀 Applying Terraform module...")
	terraform.InitAndApply(t, moduleOptions)
	t.Logf("✅ Module applied successfully")

	// Wait for ECS service to stabilize
	t.Logf("⏳ Waiting for ECS service to stabilize (30 seconds)...")
	waitForECSServiceStable(t, moduleOptions)
	t.Logf("✅ Wait complete, starting tests...")

	// Run all test suites
	t.Run("ECS Service", func(t *testing.T) {
		testECSService(t, moduleOptions, infraOutputs)
	})

	t.Run("Target Group", func(t *testing.T) {
		testTargetGroup(t, moduleOptions, infraOutputs)
	})

	t.Run("Autoscaling", func(t *testing.T) {
		testAutoscaling(t, moduleOptions, infraOutputs)
	})

	t.Run("IAM", func(t *testing.T) {
		testIAM(t, moduleOptions, infraOutputs)
	})

	t.Run("Security Group", func(t *testing.T) {
		testSecurityGroup(t, moduleOptions, infraOutputs)
	})

	t.Run("Outputs", func(t *testing.T) {
		testOutputs(t, moduleOptions)
	})
}

// Helper function to wait for ECS service to be stable
func waitForECSServiceStable(t *testing.T, moduleOptions *terraform.Options) {
	// Wait a bit for ECS service to stabilize
	time.Sleep(30 * time.Second)
}
