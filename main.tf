###############################################################################
# Local computation
#
# Keeps the resource blocks below thin and for_each-driven: derives whether the
# optional policy/data-protection resources should exist, the effective
# kms_master_key_id (secure-by-default SSE-KMS), and a per-protocol lookup for
# delivery status logging so the many <protocol>_*_feedback_* arguments on
# aws_sns_topic stay readable.
###############################################################################

locals {
 create_topic_policy = var.topic_policy_json != null
 create_data_protection_policy = var.data_protection_policy_json != null

 # enable_encryption = false => no KMS master key at all (unencrypted, opt-out).
 # enable_encryption = true => caller-supplied CMK, else the AWS-managed key.
 effective_kms_master_key_id = var.enable_encryption ? coalesce(var.kms_key_arn, "alias/aws/sns"): null

 delivery_status_logging_by_protocol = {
 for p in ["application", "http", "lambda", "sqs", "firehose"]:
 p => try(var.delivery_status_logging[p], null)
 }
}

###############################################################################
# SNS topic (keystone)
###############################################################################

resource "aws_sns_topic" "this" {
 name = var.name

 # FIFO configuration -- guarded so a standard topic never sends FIFO-only
 # arguments to the provider.
 fifo_topic = var.fifo_topic
 content_based_deduplication = var.fifo_topic ? var.content_based_deduplication: null
 fifo_throughput_scope = var.fifo_topic ? var.fifo_throughput_scope: null
 archive_policy = var.fifo_topic ? var.archive_policy_json: null

 display_name = var.display_name
 delivery_policy = var.delivery_policy_json
 signature_version = var.signature_version
 tracing_config = var.tracing_config

 # Secure by default: SSE-KMS on, AWS-managed key unless a CMK is supplied.
 kms_master_key_id = local.effective_kms_master_key_id

 # Delivery status logging -- off by default (see var.delivery_status_logging).
 application_success_feedback_role_arn = try(local.delivery_status_logging_by_protocol["application"].success_feedback_role_arn, null)
 application_success_feedback_sample_rate = try(local.delivery_status_logging_by_protocol["application"].success_feedback_sample_rate, null)
 application_failure_feedback_role_arn = try(local.delivery_status_logging_by_protocol["application"].failure_feedback_role_arn, null)

 http_success_feedback_role_arn = try(local.delivery_status_logging_by_protocol["http"].success_feedback_role_arn, null)
 http_success_feedback_sample_rate = try(local.delivery_status_logging_by_protocol["http"].success_feedback_sample_rate, null)
 http_failure_feedback_role_arn = try(local.delivery_status_logging_by_protocol["http"].failure_feedback_role_arn, null)

 lambda_success_feedback_role_arn = try(local.delivery_status_logging_by_protocol["lambda"].success_feedback_role_arn, null)
 lambda_success_feedback_sample_rate = try(local.delivery_status_logging_by_protocol["lambda"].success_feedback_sample_rate, null)
 lambda_failure_feedback_role_arn = try(local.delivery_status_logging_by_protocol["lambda"].failure_feedback_role_arn, null)

 sqs_success_feedback_role_arn = try(local.delivery_status_logging_by_protocol["sqs"].success_feedback_role_arn, null)
 sqs_success_feedback_sample_rate = try(local.delivery_status_logging_by_protocol["sqs"].success_feedback_sample_rate, null)
 sqs_failure_feedback_role_arn = try(local.delivery_status_logging_by_protocol["sqs"].failure_feedback_role_arn, null)

 firehose_success_feedback_role_arn = try(local.delivery_status_logging_by_protocol["firehose"].success_feedback_role_arn, null)
 firehose_success_feedback_sample_rate = try(local.delivery_status_logging_by_protocol["firehose"].success_feedback_sample_rate, null)
 firehose_failure_feedback_role_arn = try(local.delivery_status_logging_by_protocol["firehose"].failure_feedback_role_arn, null)

 tags = var.tags
}

###############################################################################
# Topic access policy (created only when the caller supplies a custom policy;
# otherwise SNS's own owner-account-only default policy stays in force)
###############################################################################

resource "aws_sns_topic_policy" "this" {
 for_each = local.create_topic_policy ? { this = var.topic_policy_json }: {}

 arn = aws_sns_topic.this.arn
 policy = each.value
}

###############################################################################
# Data protection policy (optional PII detection/masking -- off by default)
###############################################################################

resource "aws_sns_topic_data_protection_policy" "this" {
 for_each = local.create_data_protection_policy ? { this = var.data_protection_policy_json }: {}

 arn = aws_sns_topic.this.arn
 policy = each.value
}

###############################################################################
# Subscriptions (child collection -- for_each over map(object))
###############################################################################

resource "aws_sns_topic_subscription" "this" {
 for_each = var.subscriptions

 topic_arn = aws_sns_topic.this.arn
 protocol = each.value.protocol
 endpoint = each.value.endpoint

 # Required only when protocol = "firehose"; enforced at plan time by a
 # variable validation block on var.subscriptions.
 subscription_role_arn = try(each.value.subscription_role_arn, null)

 raw_message_delivery = try(each.value.raw_message_delivery, false)
 filter_policy = try(each.value.filter_policy, null)
 filter_policy_scope = try(each.value.filter_policy_scope, null)
 redrive_policy = try(each.value.redrive_policy, null)
 replay_policy = try(each.value.replay_policy, null)
 delivery_policy = try(each.value.delivery_policy, null)
 confirmation_timeout_in_minutes = try(each.value.confirmation_timeout_in_minutes, 1)
 endpoint_auto_confirms = try(each.value.endpoint_auto_confirms, false)
}
