package test

import (
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/iam"
	terratestaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func testIAM(t *testing.T, moduleOptions *terraform.Options, infraOutputs *InfrastructureOutputs) {
	executionRoleARN := terraform.Output(t, moduleOptions, "iam_execution_role_arn")
	serviceName := terraform.Output(t, moduleOptions, "service_name")
	awsRegion := infraOutputs.AWSRegion

	iamClient := terratestaws.NewIamClient(t, awsRegion)

	// Extract role name from ARN
	roleName := executionRoleARN[strings.LastIndex(executionRoleARN, "/")+1:]

	// Get IAM role
	role, err := iamClient.GetRole(&iam.GetRoleInput{
		RoleName: aws.String(roleName),
	})
	require.NoError(t, err)
	require.NotNil(t, role.Role)

	// Verify role name contains service name
	require.Contains(t, strings.ToLower(*role.Role.RoleName), strings.ToLower(serviceName))
	require.Contains(t, strings.ToLower(*role.Role.RoleName), "execution")

	// Verify assume role policy
	assumeRolePolicy := role.Role.AssumeRolePolicyDocument
	require.NotNil(t, assumeRolePolicy)
	require.Contains(t, *assumeRolePolicy, "ecs-tasks.amazonaws.com")

	// Get attached policies
	attachedPolicies, err := iamClient.ListAttachedRolePolicies(&iam.ListAttachedRolePoliciesInput{
		RoleName: aws.String(roleName),
	})
	require.NoError(t, err)

	// Verify AmazonECSTaskExecutionRolePolicy is attached
	found := false
	for _, policy := range attachedPolicies.AttachedPolicies {
		if strings.Contains(*policy.PolicyArn, "AmazonECSTaskExecutionRolePolicy") {
			found = true
			break
		}
	}
	require.True(t, found, "AmazonECSTaskExecutionRolePolicy should be attached to execution role")
}
