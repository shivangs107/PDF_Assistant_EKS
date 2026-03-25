#Compatibility Issue with v5
#Ensures that the correct version of Terraform and AWS provider is used to avoid compatibility issues with version 5 of the AWS provider.
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

#AWS Provider (Mumbai Region)
provider "aws" {
  region = "ap-south-1"
}

# Default VPC (No new VPC is created, using the default one)
data "aws_vpc" "default" {
  default = true
}

# Subnets from default VPC (Using all subnets in the default VPC for EKS cluster)
# EKS needs this to deploy worker nodes and control plane components across multiple availability zones for high availability.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

#EKS Cluster (Using a pre-built module from the Terraform Registry to create an EKS cluster with managed node groups)
module "eks" {
    source  = "terraform-aws-modules/eks/aws"
    version = "20.8.4"

    cluster_name = "pdf-assistant-cluster"
    cluster_version = "1.29"

    cluster_endpoint_public_access = true #Allows kubectl and other tools to access the cluster endpoint from the public internet.

    vpc_id     = data.aws_vpc.default.id
    subnet_ids = data.aws_subnets.default.ids

    #Grants IAM user access to the EKS cluster by associating the user with the AmazonEKSClusterAdminPolicy.
    access_entries = {
        admin = {
        principal_arn = "arn:aws:iam::520498584637:user/Zether"

        policy_associations = {
            admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
                type = "cluster"
            }
            }
        }
        }
    }
    #Node group (Creates EC2 instances of type t3.medium to serve as worker nodes for the EKS cluster, with a desired size of 1 and a maximum size of 2 for auto-scaling)
    eks_managed_node_groups = {
        default = {
        instance_types = ["t3.medium"]
        desired_size = 1
        min_size     = 1
        max_size     = 2
        }
    }
}

#OUTPUT (Exposes cluster name for other Terraform modules or for users to easily reference the created EKS cluster)
output "cluster_name" {
  value = module.eks.cluster_name
}