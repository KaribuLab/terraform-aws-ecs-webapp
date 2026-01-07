package test

import (
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func testTargetGroup(t *testing.T, moduleOptions *terraform.Options, infraOutputs *InfrastructureOutputs) {
	targetGroupARN := terraform.Output(t, moduleOptions, "alb_target_group_arn")

	// Verify Target Group ARN is valid
	require.NotEmpty(t, targetGroupARN)
	require.True(t, strings.HasPrefix(targetGroupARN, "arn:aws:elasticloadbalancing"))
	require.Contains(t, targetGroupARN, "targetgroup")

	// Verify Target Group name contains service name
	serviceName := terraform.Output(t, moduleOptions, "service_name")
	require.Contains(t, strings.ToLower(targetGroupARN), strings.ToLower(serviceName))
}
