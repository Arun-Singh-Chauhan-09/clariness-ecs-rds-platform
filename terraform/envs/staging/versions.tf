terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial configuration: bucket/region come from backend.hcl (local) or
  # -backend-config flags (CI). Locking uses an S3 lock file, no DynamoDB.
  backend "s3" {
    key          = "staging/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  tags = {
    Project     = "referrals-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "clariness-ecs-rds-platform"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

# Second region for cross-region backup replication (DR).
provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = local.tags
  }
}
