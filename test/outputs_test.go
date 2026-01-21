package test

import (
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func testOutputs(t *testing.T, moduleOptions *terraform.Options, infraOutputs *InfrastructureOutputs) {
	// Test all outputs exist and have values
	albTargetGroupARN := terraform.Output(t, moduleOptions, "alb_target_group_arn")
	if infraOutputs.ALBListenerARN != "" {
		// ALB is configured, verify target group ARN
		require.NotEmpty(t, albTargetGroupARN, "Target Group ARN should not be empty when ALB is configured")
		require.True(t, strings.HasPrefix(albTargetGroupARN, "arn:aws:elasticloadbalancing"))
	} else {
		// ALB is not configured, target group ARN should be empty/null
		require.Empty(t, albTargetGroupARN, "Target Group ARN should be empty when ALB is not configured")
	}

	ecsServiceName := terraform.Output(t, moduleOptions, "ecs_service_name")
	require.NotEmpty(t, ecsServiceName)

	ecsTaskDefinitionARN := terraform.Output(t, moduleOptions, "ecs_task_definition_arn")
	require.NotEmpty(t, ecsTaskDefinitionARN)
	require.True(t, strings.HasPrefix(ecsTaskDefinitionARN, "arn:aws:ecs"))

	iamExecutionRoleARN := terraform.Output(t, moduleOptions, "iam_execution_role_arn")
	require.NotEmpty(t, iamExecutionRoleARN)
	require.True(t, strings.HasPrefix(iamExecutionRoleARN, "arn:aws:iam"))

	clusterName := terraform.Output(t, moduleOptions, "cluster_name")
	require.NotEmpty(t, clusterName)

	serviceName := terraform.Output(t, moduleOptions, "service_name")
	require.NotEmpty(t, serviceName)
	require.Equal(t, ecsServiceName, serviceName)

	securityGroupID := terraform.Output(t, moduleOptions, "security_group_id")
	require.NotEmpty(t, securityGroupID)
	require.True(t, strings.HasPrefix(securityGroupID, "sg-"))

	// Verify outputs are consistent
	require.Contains(t, strings.ToLower(iamExecutionRoleARN), strings.ToLower(serviceName))
	require.Contains(t, strings.ToLower(iamExecutionRoleARN), "execution")
}
