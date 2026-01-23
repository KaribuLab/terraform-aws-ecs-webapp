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

	// Get inline policies
	inlinePolicies, err := iamClient.ListRolePolicies(&iam.ListRolePoliciesInput{
		RoleName: aws.String(roleName),
	})
	require.NoError(t, err)

	// Find the secrets policy
	var secretsPolicyName string
	for _, policyName := range inlinePolicies.PolicyNames {
		if strings.Contains(*policyName, "execution-secrets-policy") {
			secretsPolicyName = *policyName
			break
		}
	}
	require.NotEmpty(t, secretsPolicyName, "Secrets policy should exist when secret_variables are provided")

	// Get policy document
	policyDoc, err := iamClient.GetRolePolicy(&iam.GetRolePolicyInput{
		RoleName:   aws.String(roleName),
		PolicyName: aws.String(secretsPolicyName),
	})
	require.NoError(t, err)
	require.NotNil(t, policyDoc.PolicyDocument)

	// Verify policy contains required actions based on the types of secrets used
	policyDocStr := *policyDoc.PolicyDocument
	
	// Check for SSM permissions (TestSecret and APIKey are SSM parameters)
	require.Contains(t, policyDocStr, "ssm:GetParameters", "Policy should contain SSM Parameter Store permissions")
	require.Contains(t, policyDocStr, infraOutputs.TestSecretARN, "Policy should contain TestSecret ARN")
	require.Contains(t, policyDocStr, infraOutputs.APIKeyARN, "Policy should contain APIKey ARN")
	
	// Check for Secrets Manager permissions (DatabasePassword is a Secrets Manager secret)
	require.Contains(t, policyDocStr, "secretsmanager:GetSecretValue", "Policy should contain Secrets Manager permissions")
	require.Contains(t, policyDocStr, infraOutputs.DatabasePasswordARN, "Policy should contain DatabasePassword ARN")

	t.Logf("✅ Secrets policy verified successfully")
	t.Logf("   Policy name: %s", secretsPolicyName)
	t.Logf("   Contains SSM permissions: ✓")
	t.Logf("   Contains Secrets Manager permissions: ✓")
	t.Logf("   Contains TestSecret ARN (SSM): ✓")
	t.Logf("   Contains APIKey ARN (SSM): ✓")
	t.Logf("   Contains DatabasePassword ARN (Secrets Manager): ✓")
}
