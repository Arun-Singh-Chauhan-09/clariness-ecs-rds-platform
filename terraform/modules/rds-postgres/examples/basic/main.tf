# Minimal usage example. It also lets CI validate the module: the module needs
# an aliased provider (aws.dr) that only a caller can pass in, so
# `terraform validate` cannot run on the module directory by itself.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

provider "aws" {
  alias  = "dr"
  region = "eu-west-1"
}

module "rds" {
  source = "../.."
  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  identifier = "referrals-example"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
}

output "address" {
  description = "Endpoint of the example instance."
  value       = module.rds.address
}
