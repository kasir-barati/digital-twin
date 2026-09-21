# "data" is the Terraform block type for a read-only data source.
# "aws_caller_identity" is the data source type, defined by the AWS provider.
# "current" is a local name I choose. Just a simple identifier.
# "{}" is configuration arguments. It is empty because aws_caller_identity requires no arguments.
# The provider exposes a schema saying: "I have a data source called aws_caller_identity with computed attributes account_id, arn, and user_id."
data "aws_caller_identity" "current" {}

# Optional: Custom domain configuration (only created when use_custom_domain = true)
data "aws_route53_zone" "root" {
  count        = var.use_custom_domain ? 1 : 0
  name         = var.root_domain
  private_zone = false
}
