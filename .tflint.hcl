plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Optional: AWS-specific rules (invalid instance types etc.). Pin a current
# release from github.com/terraform-linters/tflint-ruleset-aws/releases:
# plugin "aws" {
#   enabled = true
#   version = "<x.y.z>"
#   source  = "github.com/terraform-linters/tflint-ruleset-aws"
# }
