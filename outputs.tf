###############################################################################
# Primary outputs (id + arn)
###############################################################################

output "id" {
 description = <<EOT
The ARN of the SNS topic. NOTE: for aws_sns_topic, id and arn are the
IDENTICAL value -- SNS has no separate short resource id. Emitted anyway per
the house id + arn output convention so this module's contract matches every
other terraform-aws-* module.
EOT
 value = aws_sns_topic.this.id
}

output "arn" {
 description = <<EOT
The ARN of the SNS topic (arn:aws:sns:<region>:<account-id>:<name>) -- the
cross-resource reference type. Consumed by terraform-aws-sqs (queue policy
Condition.ArnEquals), terraform-aws-iam-policy (publish/subscribe grants),
CloudWatch alarm actions, and Lambda event-source / DLQ targets.
EOT
 value = aws_sns_topic.this.arn
}

###############################################################################
# Topic attributes
###############################################################################

output "name" {
 description = "The name of the SNS topic. Consumed by tagging, monitoring, dashboards, and naming-convention audits."
 value = aws_sns_topic.this.name
}

output "owner" {
 description = "The AWS account id of the SNS topic owner. Consumed by cross-account policy authoring and audit."
 value = aws_sns_topic.this.owner
}

output "beginning_archive_time" {
 description = "The oldest timestamp at which a FIFO topic subscriber can start a replay; empty for standard topics or FIFO topics with no archive_policy_json set."
 value = aws_sns_topic.this.beginning_archive_time
}

###############################################################################
# Access / data protection policy status
###############################################################################

output "topic_policy_attached" {
 description = "Whether a custom aws_sns_topic_policy was created (true when topic_policy_json was supplied). When false, SNS's owner-account-only default policy is in force."
 value = local.create_topic_policy
}

output "data_protection_policy_enabled" {
 description = "Whether an aws_sns_topic_data_protection_policy was created (true when data_protection_policy_json was supplied)."
 value = local.create_data_protection_policy
}

###############################################################################
# Subscriptions
###############################################################################

output "subscription_arns" {
 description = "Map (keyed by the caller's subscriptions key) of subscription ARNs."
 value = { for k, s in aws_sns_topic_subscription.this: k => s.arn }
}

output "subscription_pending_confirmation" {
 description = <<EOT
Map (keyed by the caller's subscriptions key) of pending_confirmation
booleans. true means the subscription is awaiting manual confirmation outside
Terraform's control (http/https/email/email-json protocols without
endpoint_auto_confirms = true) -- see the README's AWS Prerequisites section.
EOT
 value = { for k, s in aws_sns_topic_subscription.this: k => s.pending_confirmation }
}

output "subscription_confirmation_was_authenticated" {
 description = "Map (keyed by the caller's subscriptions key) of confirmation_was_authenticated booleans."
 value = { for k, s in aws_sns_topic_subscription.this: k => s.confirmation_was_authenticated }
}

output "subscription_owner_ids" {
 description = "Map (keyed by the caller's subscriptions key) of AWS account ids owning each subscription."
 value = { for k, s in aws_sns_topic_subscription.this: k => s.owner_id }
}

###############################################################################
# Tags
###############################################################################

output "tags_all" {
 description = <<EOT
All tags on the topic, including those inherited from provider default_tags
(resource tags win on key conflict). Only aws_sns_topic carries tags in this
composite -- the policy, subscription, and data-protection-policy resources
have no tags/tags_all attribute in the AWS provider schema.
EOT
 value = aws_sns_topic.this.tags_all
}
