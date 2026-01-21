package test

import (
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/ecs"
	terratestaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func testECSService(t *testing.T, moduleOptions *terraform.Options, infraOutputs *InfrastructureOutputs) {
	clusterName := terraform.Output(t, moduleOptions, "cluster_name")
	serviceName := terraform.Output(t, moduleOptions, "service_name")
	taskDefinitionARN := terraform.Output(t, moduleOptions, "ecs_task_definition_arn")
	region := infraOutputs.AWSRegion

	t.Logf("🔍 Testing ECS Service")
	t.Logf("   Cluster Name: %s", clusterName)
	t.Logf("   Service Name: %s", serviceName)
	t.Logf("   Task Definition ARN: %s", taskDefinitionARN)
	t.Logf("   Region: %s", region)

	// Get ECS service
	ecsClient := terratestaws.NewEcsClient(t, region)
	t.Logf("📡 Calling DescribeServices API...")
	service, err := ecsClient.DescribeServices(&ecs.DescribeServicesInput{
		Cluster:  aws.String(clusterName),
		Services: []*string{aws.String(serviceName)},
	})

	if err != nil {
		t.Logf("❌ Error describing service: %v", err)
	}
	require.NoError(t, err)

	t.Logf("✅ DescribeServices successful, found %d service(s)", len(service.Services))
	if len(service.Services) == 0 {
		t.Logf("⚠️  No services found! This might be the issue.")
		t.Logf("   Attempted to find service '%s' in cluster '%s'", serviceName, clusterName)
		return
	}

	require.Len(t, service.Services, 1)

	// Verify service properties
	ecsService := service.Services[0]
	t.Logf("📋 Verifying service properties...")
	t.Logf("   Service Name: %s (expected: %s)", *ecsService.ServiceName, serviceName)
	require.Equal(t, serviceName, *ecsService.ServiceName)

	t.Logf("   Cluster ARN: %s (checking if contains cluster name: %s)", *ecsService.ClusterArn, clusterName)
	// Extract cluster name from ARN (format: arn:aws:ecs:region:account:cluster/cluster-name)
	clusterArnParts := strings.Split(*ecsService.ClusterArn, "/")
	require.Greater(t, len(clusterArnParts), 1, "Cluster ARN should contain '/' separator")
	actualClusterName := clusterArnParts[len(clusterArnParts)-1]
	t.Logf("   Extracted cluster name from ARN: %s (expected: %s)", actualClusterName, clusterName)
	require.Equal(t, clusterName, actualClusterName)

	t.Logf("   Launch Type: %s", *ecsService.LaunchType)
	require.Equal(t, "FARGATE", *ecsService.LaunchType)

	t.Logf("   Desired Count: %d (expected: 1)", *ecsService.DesiredCount)
	require.Equal(t, int64(1), *ecsService.DesiredCount)

	// Verify task definition
	t.Logf("   Task Definition ARN: %s (expected: %s)", *ecsService.TaskDefinition, taskDefinitionARN)
	require.Equal(t, taskDefinitionARN, *ecsService.TaskDefinition)

	// Verify network configuration
	t.Logf("🌐 Verifying network configuration...")
	require.NotNil(t, ecsService.NetworkConfiguration)
	require.NotNil(t, ecsService.NetworkConfiguration.AwsvpcConfiguration)

	assignPublicIP := *ecsService.NetworkConfiguration.AwsvpcConfiguration.AssignPublicIp
	t.Logf("   Assign Public IP: %s (expected: DISABLED)", assignPublicIP)
	require.Equal(t, "DISABLED", assignPublicIP)

	expectedSubnetCount := len(infraOutputs.PrivateSubnetIDs)
	actualSubnetCount := len(ecsService.NetworkConfiguration.AwsvpcConfiguration.Subnets)
	t.Logf("   Subnet Count: %d (expected: %d)", actualSubnetCount, expectedSubnetCount)
	require.Equal(t, expectedSubnetCount, actualSubnetCount)

	// Verify load balancer configuration (only if ALB is configured)
	if infraOutputs.ALBListenerARN != "" {
		t.Logf("⚖️  Verifying load balancer configuration...")
		t.Logf("   Load Balancers count: %d (expected: 1)", len(ecsService.LoadBalancers))
		require.Len(t, ecsService.LoadBalancers, 1, "Service should have exactly one load balancer when ALB is configured")
		loadBalancer := ecsService.LoadBalancers[0]

		if loadBalancer.TargetGroupArn != nil {
			t.Logf("   Target Group ARN: %s", *loadBalancer.TargetGroupArn)
		} else {
			t.Logf("   ❌ Target Group ARN is nil!")
		}
		require.NotNil(t, loadBalancer.TargetGroupArn)

		t.Logf("   Container Name: %s (expected: %s)", *loadBalancer.ContainerName, serviceName)
		require.Equal(t, serviceName, *loadBalancer.ContainerName)
	} else {
		t.Logf("⚖️  Verifying load balancer configuration (ALB not configured)...")
		t.Logf("   Load Balancers count: %d (expected: 0)", len(ecsService.LoadBalancers))
		require.Len(t, ecsService.LoadBalancers, 0, "Service should not have load balancer when ALB is not configured")
	}

	// Get task definition
	t.Logf("📦 Getting task definition...")
	taskDef, err := ecsClient.DescribeTaskDefinition(&ecs.DescribeTaskDefinitionInput{
		TaskDefinition: aws.String(taskDefinitionARN),
	})
	if err != nil {
		t.Logf("❌ Error getting task definition: %v", err)
	}
	require.NoError(t, err)
	require.NotNil(t, taskDef.TaskDefinition)

	// Verify container definitions
	t.Logf("🐳 Verifying container definitions...")
	t.Logf("   Container definitions count: %d (expected: 1)", len(taskDef.TaskDefinition.ContainerDefinitions))
	require.Len(t, taskDef.TaskDefinition.ContainerDefinitions, 1)
	containerDef := taskDef.TaskDefinition.ContainerDefinitions[0]

	t.Logf("   Container Name: %s (expected: %s)", *containerDef.Name, serviceName)
	require.Equal(t, serviceName, *containerDef.Name)

	t.Logf("   Container Image: %s (expected: nginx:latest)", *containerDef.Image)
	require.Equal(t, "nginx:latest", *containerDef.Image)

	t.Logf("   Essential: %v (expected: true)", *containerDef.Essential)
	require.True(t, *containerDef.Essential)

	// Verify port mappings
	t.Logf("🔌 Verifying port mappings...")
	t.Logf("   Port mappings count: %d (expected: 1)", len(containerDef.PortMappings))
	require.Len(t, containerDef.PortMappings, 1)

	if len(containerDef.PortMappings) > 0 {
		t.Logf("   Container Port: %d (expected: 80)", *containerDef.PortMappings[0].ContainerPort)
		t.Logf("   Protocol: %s (expected: tcp)", *containerDef.PortMappings[0].Protocol)
	}
	require.Equal(t, int64(80), *containerDef.PortMappings[0].ContainerPort)
	require.Equal(t, "tcp", *containerDef.PortMappings[0].Protocol)

	// Verify secret variables from SSM Parameter Store
	t.Logf("🔐 Verifying secret variables from SSM Parameter Store...")
	t.Logf("   Secrets count: %d (expected: 2)", len(containerDef.Secrets))
	require.Len(t, containerDef.Secrets, 2, "Container should have 2 secrets configured")

	// Expected secrets with their SSM Parameter Store ARNs
	expectedSecrets := map[string]string{
		"TEST_SECRET": infraOutputs.TestSecretARN,
		"API_KEY":     infraOutputs.APIKeyARN,
	}

	// Verify each secret is present and uses the correct SSM ARN
	foundSecrets := make(map[string]bool)
	for _, secret := range containerDef.Secrets {
		if secret.Name != nil {
			secretName := *secret.Name
			t.Logf("   Secret Name: %s", secretName)

			// Verify ValueFrom is set (required for SSM Parameter Store)
			require.NotNil(t, secret.ValueFrom, "Secret %s should have ValueFrom set", secretName)
			if secret.ValueFrom != nil {
				valueFrom := *secret.ValueFrom
				t.Logf("   Secret %s: ValueFrom = %s", secretName, valueFrom)

				// Verify the ARN matches the expected SSM parameter ARN
				if expectedARN, exists := expectedSecrets[secretName]; exists {
					// The ValueFrom should be the ARN of the SSM parameter
					require.Equal(t, expectedARN, valueFrom, "Secret %s should reference SSM parameter ARN %s", secretName, expectedARN)
					foundSecrets[secretName] = true
					t.Logf("   ✅ Secret %s correctly references SSM Parameter Store", secretName)
				}
			}
		}
	}

	// Verify all expected secrets were found
	for secretName := range expectedSecrets {
		require.True(t, foundSecrets[secretName], "Secret %s should be present in container definition", secretName)
	}

	// Verify log configuration
	t.Logf("📝 Verifying log configuration...")
	if containerDef.LogConfiguration == nil {
		t.Logf("   ❌ LogConfiguration is nil!")
	}
	require.NotNil(t, containerDef.LogConfiguration)

	if containerDef.LogConfiguration.LogDriver != nil {
		t.Logf("   Log Driver: %s (expected: awslogs)", *containerDef.LogConfiguration.LogDriver)
	}
	require.Equal(t, "awslogs", *containerDef.LogConfiguration.LogDriver)

	logGroupNamePtr, exists := containerDef.LogConfiguration.Options["awslogs-group"]
	if !exists {
		t.Logf("   ❌ awslogs-group key not found in log configuration options")
	} else {
		var logGroupName string
		if logGroupNamePtr != nil {
			logGroupName = *logGroupNamePtr
		}
		t.Logf("   Log Group: %s (expected: %s)", logGroupName, infraOutputs.CloudWatchLogGroupName)
	}
	require.Contains(t, containerDef.LogConfiguration.Options, "awslogs-group")
	logGroupNameValue := containerDef.LogConfiguration.Options["awslogs-group"]
	if logGroupNameValue != nil {
		require.Equal(t, infraOutputs.CloudWatchLogGroupName, *logGroupNameValue)
	} else {
		t.Fatal("awslogs-group value is nil")
	}

	// Verify deployment configuration
	t.Logf("🚀 Verifying deployment configuration...")
	if ecsService.DeploymentConfiguration == nil {
		t.Logf("   ❌ DeploymentConfiguration is nil!")
	}
	require.NotNil(t, ecsService.DeploymentConfiguration)

	if ecsService.DeploymentConfiguration.MaximumPercent != nil {
		t.Logf("   Maximum Percent: %d (expected: 200)", *ecsService.DeploymentConfiguration.MaximumPercent)
	}
	require.Equal(t, int64(200), *ecsService.DeploymentConfiguration.MaximumPercent)

	if ecsService.DeploymentConfiguration.MinimumHealthyPercent != nil {
		t.Logf("   Minimum Healthy Percent: %d (expected: 100)", *ecsService.DeploymentConfiguration.MinimumHealthyPercent)
	}
	require.Equal(t, int64(100), *ecsService.DeploymentConfiguration.MinimumHealthyPercent)

	t.Logf("✅ All ECS Service tests passed!")
}
