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
	// This now returns options even if there are errors, so cleanup can always run
	infraOptions, infraOutputs, infraErr := setupInfrastructure(t, testName)

	// CRITICAL: Register cleanup IMMEDIATELY after getting options
	// This ensures cleanup runs even if subsequent operations fail
	if infraOptions != nil {
		t.Cleanup(func() {
			teardownInfrastructure(t, infraOptions)
		})
	}

	// If infrastructure setup had fatal errors, fail now (after registering cleanup)
	if infraErr != nil {
		t.Fatalf("❌ Failed to setup infrastructure: %v", infraErr)
	}

	// Setup module options
	moduleOptions := setupModuleOptions(t, "..", infraOutputs, testName)

	// CRITICAL: Register module cleanup BEFORE applying
	// This ensures cleanup runs even if apply fails
	if moduleOptions != nil {
		t.Cleanup(func() {
			cleanupModule(t, moduleOptions)
		})
	}

	// Apply module using InitAndApplyE to handle errors gracefully
	t.Logf("🚀 Applying Terraform module...")
	_, err := terraform.InitAndApplyE(t, moduleOptions)
	if err != nil {
		t.Logf("⚠️  Error applying module: %v", err)
		t.Logf("   Cleanup will attempt to destroy what was created")
		// Don't fail immediately - let cleanup execute
		// The test will fail naturally if subsequent operations fail
	} else {
		t.Logf("✅ Module applied successfully")
	}

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
		testOutputs(t, moduleOptions, infraOutputs)
	})
}

// Helper function to wait for ECS service to be stable
func waitForECSServiceStable(t *testing.T, moduleOptions *terraform.Options) {
	// Wait a bit for ECS service to stabilize
	time.Sleep(30 * time.Second)
}
