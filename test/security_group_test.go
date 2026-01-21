package test

import (
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/ec2"
	terratestaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func testSecurityGroup(t *testing.T, moduleOptions *terraform.Options, infraOutputs *InfrastructureOutputs) {
	securityGroupID := terraform.Output(t, moduleOptions, "security_group_id")
	serviceName := terraform.Output(t, moduleOptions, "service_name")
	region := infraOutputs.AWSRegion

	ec2Client := terratestaws.NewEc2Client(t, region)

	// Get Security Group
	sg, err := ec2Client.DescribeSecurityGroups(&ec2.DescribeSecurityGroupsInput{
		GroupIds: []*string{aws.String(securityGroupID)},
	})
	require.NoError(t, err)
	require.Len(t, sg.SecurityGroups, 1)

	securityGroup := sg.SecurityGroups[0]

	// Verify Security Group properties
	require.Equal(t, securityGroupID, *securityGroup.GroupId)
	require.Equal(t, infraOutputs.VPCID, *securityGroup.VpcId)
	require.Contains(t, strings.ToLower(*securityGroup.GroupName), strings.ToLower(serviceName))

	// Verify ingress rules
	ingressRules := securityGroup.IpPermissions
	require.Greater(t, len(ingressRules), 0)

	// Find rule allowing traffic from ALB security group (only if ALB is configured)
	foundALBRule := false
	foundVPCRule := false
	for _, rule := range ingressRules {
		if *rule.IpProtocol == "tcp" && len(rule.UserIdGroupPairs) > 0 {
			for _, pair := range rule.UserIdGroupPairs {
				if infraOutputs.ALBSecurityGroupID != "" && *pair.GroupId == infraOutputs.ALBSecurityGroupID {
					foundALBRule = true
					require.Equal(t, int64(80), *rule.FromPort)
					require.Equal(t, int64(80), *rule.ToPort)
				}
			}
		}
		if *rule.IpProtocol == "tcp" && len(rule.IpRanges) > 0 {
			for _, ipRange := range rule.IpRanges {
				// Check if it's the VPC CIDR (10.0.0.0/16)
				if *ipRange.CidrIp == "10.0.0.0/16" {
					foundVPCRule = true
				}
			}
		}
	}
	if infraOutputs.ALBSecurityGroupID != "" {
		require.True(t, foundALBRule, "Security group should allow traffic from ALB security group when ALB is configured")
	} else {
		t.Logf("   ALB not configured, skipping ALB security group rule check")
	}
	require.True(t, foundVPCRule, "Security group should allow traffic from VPC")

	// Verify egress rules (should allow all outbound)
	egressRules := securityGroup.IpPermissionsEgress
	require.Greater(t, len(egressRules), 0)
	foundEgressAll := false
	for _, rule := range egressRules {
		if *rule.IpProtocol == "-1" && len(rule.IpRanges) > 0 {
			for _, ipRange := range rule.IpRanges {
				if *ipRange.CidrIp == "0.0.0.0/0" {
					foundEgressAll = true
					break
				}
			}
		}
	}
	require.True(t, foundEgressAll, "Security group should allow all outbound traffic")
}
