terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name      = "terratest-fixtures-vpc"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name      = "terratest-fixtures-igw"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Public Subnets (for ALB)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name      = "terratest-fixtures-public-subnet-${count.index + 1}"
    Type      = "public"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Private Subnets (for ECS)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name      = "terratest-fixtures-private-subnet-${count.index + 1}"
    Type      = "private"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"

  tags = {
    Name      = "terratest-fixtures-nat-eip-${count.index + 1}"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }

  depends_on = [aws_internet_gateway.main]
}

# NAT Gateway
resource "aws_nat_gateway" "main" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name      = "terratest-fixtures-nat-${count.index + 1}"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name      = "terratest-fixtures-public-rt"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Route Table Associations for Public Subnets
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Route Tables for Private Subnets
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name      = "terratest-fixtures-private-rt-${count.index + 1}"
    ManagedBy = "terratest"
    TestName  = "terratest-fixtures"
  }
}

# Route Table Associations for Private Subnets
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
