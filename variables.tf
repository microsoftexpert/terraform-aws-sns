###############################################################################
# Identity
###############################################################################

variable "name" {
 description = <<EOT
Name of the SNS topic. Must be 1-256 characters of uppercase/lowercase ASCII
letters, numbers, underscores, and hyphens. FIFO topics (fifo_topic = true)
MUST end in the ".fifo" suffix, e.g. "orders.fifo". Treat this as effectively
FORCE-NEW in practice -- SNS does not support renaming a topic, so changing
this value destroys and recreates aws_sns_topic.this and, transitively, every
subscription and policy attached to it.
EOT
 type = string

 validation {
 condition = can(regex("^[A-Za-z0-9_-]{1,256}$", var.name)) || can(regex("^[A-Za-z0-9_-]{1,251}\\.fifo$", var.name))
 error_message = "name must be 1-256 characters of letters, numbers, underscores, and hyphens (FIFO topics: the same charset plus a mandatory.fifo suffix, e.g. \"orders.fifo\")."
 }

 validation {
 condition = !var.fifo_topic || endswith(var.name, ".fifo")
 error_message = "name must end in \".fifo\" when fifo_topic = true."
 }
}

###############################################################################
# FIFO configuration
###############################################################################

variable "fifo_topic" {
 description = <<EOT
Whether to create a FIFO (first-in-first-out) topic instead of a standard
topic. FORCE-NEW -- standard <-> FIFO is not an in-place update; changing this
replaces the topic (and, transitively, every subscription and policy attached
to it). FIFO topics preserve strict message ordering and support
deduplication but can only deliver to "sqs" and "firehose" subscription
protocols, never http/https/email/email-json/sms/application. Defaults to
false (standard topic).
EOT
 type = bool
 default = false
}

variable "content_based_deduplication" {
 description = <<EOT
Whether to enable content-based deduplication on a FIFO topic (SNS computes a
SHA-256 hash of the message body as the deduplication ID when the publisher
does not supply an explicit one). NOT force-new -- can be flipped in place on
an existing FIFO topic. Ignored (never sent to the provider) when fifo_topic
is false. Defaults to false.
EOT
 type = bool
 default = false
}

variable "fifo_throughput_scope" {
 description = <<EOT
Deduplication scope for a high-throughput FIFO topic. Ignored when fifo_topic
is false. One of:
 - null: (default) standard FIFO throughput (300 msg/s per message
 group, 300 msg/s per topic).
 - "Topic": deduplicates across the whole topic; matches classic FIFO
 dedup semantics at the higher throughput ceiling.
 - "MessageGroup": deduplicates per message group, unlocking the full
 high-throughput FIFO rate partitioned across message
 groups.
EOT
 type = string
 default = null

 validation {
 condition = var.fifo_throughput_scope == null || contains(["Topic", "MessageGroup"], var.fifo_throughput_scope)
 error_message = "fifo_throughput_scope must be \"Topic\", \"MessageGroup\", or null."
 }
}

variable "archive_policy_json" {
 description = <<EOT
JSON-encoded message archive policy for a FIFO topic (enables message replay
via a subscription's replay_policy). Ignored when fifo_topic is false. Null
(default) disables archiving. Example: jsonencode({ MessageRetentionPeriod = 7 })
EOT
 type = string
 default = null

 validation {
 condition = var.archive_policy_json == null || can(jsondecode(var.archive_policy_json))
 error_message = "archive_policy_json must be valid JSON, or null."
 }
}

###############################################################################
# Topic configuration
###############################################################################

variable "display_name" {
 description = "Display name for the topic -- used as the sender ID on SMS deliveries. Null (default) leaves it unset."
 type = string
 default = null
}

variable "delivery_policy_json" {
 description = <<EOT
JSON-encoded HTTP delivery retry policy (retry backoff, throttle) applied at
the topic level to HTTP/S subscribers, wrapped in a top-level "http" object
per the AWS delivery-policy schema (unlike a subscription's own
delivery_policy, which is NOT wrapped). Null (default) uses the AWS default
retry policy.
EOT
 type = string
 default = null

 validation {
 condition = var.delivery_policy_json == null || can(jsondecode(var.delivery_policy_json))
 error_message = "delivery_policy_json must be valid JSON, or null."
 }
}

variable "signature_version" {
 description = <<EOT
Hash algorithm used to sign notification, subscription-confirmation, and
unsubscribe-confirmation messages published by SNS. "1" = SHA1 (AWS default),
"2" = SHA256 (recommended for topics that need stronger message signatures).
EOT
 type = string
 default = "1"

 validation {
 condition = contains(["1", "2"], var.signature_version)
 error_message = "signature_version must be \"1\" or \"2\"."
 }
}

variable "tracing_config" {
 description = <<EOT
AWS X-Ray active tracing mode for the topic. "PassThrough" (default, AWS
default) forwards an existing trace context without sampling; "Active"
samples and traces messages published to the topic.
EOT
 type = string
 default = "PassThrough"

 validation {
 condition = contains(["PassThrough", "Active"], var.tracing_config)
 error_message = "tracing_config must be \"PassThrough\" or \"Active\"."
 }
}

###############################################################################
# Delivery status logging (off by default -- see SCOPE.md secure-by-default
# decisions: avoids requiring a CloudWatch Logs IAM role for every protocol)
###############################################################################

variable "delivery_status_logging" {
 description = <<EOT
Optional per-protocol delivery status logging to CloudWatch Logs, keyed by
protocol name. Off by default (baseline -- no CloudWatch Logs IAM role is
required unless explicitly opted in). Each key MUST be one of "application",
"http", "lambda", "sqs", "firehose" and maps to the matching aws_sns_topic
<protocol>_success_feedback_role_arn / _success_feedback_sample_rate /
_failure_feedback_role_arn arguments.

 delivery_status_logging = {
 sqs = {
 success_feedback_role_arn = module.sns_logging_role.arn
 success_feedback_sample_rate = 100
 failure_feedback_role_arn = module.sns_logging_role.arn
 }
 }

Per-entry fields:
 - success_feedback_role_arn: (Optional) IAM role SNS assumes to write
 successful-delivery samples to CloudWatch
 Logs.
 - success_feedback_sample_rate: (Optional) 0-100 percent of successful
 deliveries to sample.
 - failure_feedback_role_arn: (Optional) IAM role SNS assumes to write
 every failed delivery to CloudWatch Logs.
EOT
 type = map(object({
 success_feedback_role_arn = optional(string)
 success_feedback_sample_rate = optional(number)
 failure_feedback_role_arn = optional(string)
 }))
 default = {}

 validation {
 condition = alltrue([for k in keys(var.delivery_status_logging): contains(["application", "http", "lambda", "sqs", "firehose"], k)])
 error_message = "delivery_status_logging keys must be one of: application, http, lambda, sqs, firehose."
 }

 validation {
 condition = alltrue([
 for k, v in var.delivery_status_logging:
 v.success_feedback_sample_rate == null || (v.success_feedback_sample_rate >= 0 && v.success_feedback_sample_rate <= 100)
 ])
 error_message = "delivery_status_logging[*].success_feedback_sample_rate must be between 0 and 100."
 }
}

###############################################################################
# Encryption at rest (secure by default -- SSE-KMS ON)
###############################################################################

variable "enable_encryption" {
 description = <<EOT
Whether server-side encryption (SSE-KMS) is enabled for the topic (secure
baseline -- ON by default). When true and kms_key_arn is null, the topic uses
the AWS-managed key alias "alias/aws/sns". Set false only with a documented
exception -- an unencrypted topic stores message bodies at rest without a KMS
envelope.
EOT
 type = bool
 default = true
}

variable "kms_key_arn" {
 description = <<EOT
ARN, key id, or alias of a customer-managed KMS key (CMK) used for SSE-KMS.
Null (default) uses the AWS-managed key alias/aws/sns when enable_encryption
is true. Wire from tf-mod-aws-kms (arn output) for a CMK. Ignored entirely
when enable_encryption is false.

NOTE: the CMK's own key policy (NOT this module's caller identity) must grant
kms:Decrypt / kms:GenerateDataKey* to the publishing/subscribing principals
(and to sns.amazonaws.com where relevant) -- see the README's Required IAM
Permissions section. Forgetting this is the most common cause of a
KMS.AccessDeniedException at publish time.
EOT
 type = string
 default = null
}

###############################################################################
# Topic access policy (owner-only default unless a custom policy is supplied)
###############################################################################

variable "topic_policy_json" {
 description = <<EOT
Full SNS topic access policy as a JSON-encoded string, rendered as a separate
aws_sns_topic_policy resource. Null (default) creates NO topic policy
resource at all, leaving SNS's own owner-account-only default policy in
force (no cross-account or public access). Supply a custom document (e.g. via
data.aws_iam_policy_document) to grant cross-account publish/subscribe, allow
an AWS service principal to publish (CloudWatch alarms, S3 event
notifications, Cost Anomaly Detection, etc.), or otherwise widen access --
scope it as tightly as possible; this module does not validate the document's
principals or actions.
EOT
 type = string
 default = null

 validation {
 condition = var.topic_policy_json == null || can(jsondecode(var.topic_policy_json))
 error_message = "topic_policy_json must be valid JSON, or null."
 }
}

###############################################################################
# Data protection policy (optional PII detection/masking -- off by default)
###############################################################################

variable "data_protection_policy_json" {
 description = <<EOT
Optional SNS data protection policy (PII/sensitive-data detection, masking,
or denial on message bodies) as a JSON-encoded string, rendered as a separate
aws_sns_topic_data_protection_policy resource. Null (default, OFF) -- this is
a distinct, separately-billed inline-inspection feature, so it is opt-in
rather than assumed for every topic. Build with jsonencode() following the
AWS data-protection-policy schema (Description, Name, Statement[] with
DataDirection / DataIdentifier / Operation / Principal / Sid).
EOT
 type = string
 default = null

 validation {
 condition = var.data_protection_policy_json == null || can(jsondecode(var.data_protection_policy_json))
 error_message = "data_protection_policy_json must be valid JSON, or null."
 }
}

###############################################################################
# Subscriptions (child collection -- for_each over map(object))
###############################################################################

variable "subscriptions" {
 description = <<EOT
Map of subscriptions on this topic, keyed by a caller-chosen stable name (a
map, not a list, so adding/removing one subscription never perturbs the
others under for_each). Each entry renders one aws_sns_topic_subscription.

 subscriptions = {
 billing-queue = {
 protocol = "sqs"
 endpoint = module.sqs_billing.arn
 }
 ops-email = {
 protocol = "email"
 endpoint = "ops@example.com"
 }
 firehose-archive = {
 protocol = "firehose"
 endpoint = module.firehose_archive.arn
 subscription_role_arn = module.firehose_subscribe_role.arn
 }
 }

Per-subscription fields:
 - protocol: (Required) One of "sqs", "sms", "lambda",
 "firehose", "application", "email",
 "email-json", "http", "https". FIFO
 topics support only "sqs" and "firehose".
 - endpoint: (Required) Destination; shape depends on
 protocol -- queue/function/delivery-stream
 ARN, phone number, URL, or email address.
 - subscription_role_arn: (Required when protocol = "firehose") IAM
 role ARN SNS assumes to publish to the
 Kinesis Data Firehose delivery stream.
 Wire from tf-mod-aws-iam-role.
 - raw_message_delivery: (Optional) Deliver the raw message body
 instead of wrapping it in the SNS JSON
 envelope. Default false.
 - filter_policy: (Optional) JSON-encoded filter policy
 scoping which published messages this
 subscriber receives.
 - filter_policy_scope: (Optional) "MessageAttributes" (default)
 or "MessageBody" -- which part of the
 message filter_policy evaluates against.
 - redrive_policy: (Optional) JSON-encoded dead-letter-queue
 redrive policy (deadLetterTargetArn).
 - replay_policy: (Optional) JSON-encoded archived-message
 replay policy (FIFO topics with
 archive_policy_json set only).
 - delivery_policy: (Optional) JSON-encoded HTTP retry policy
 (http/https protocols only) -- NOT
 wrapped in a top-level "http" object,
 unlike the topic-level
 delivery_policy_json.
 - confirmation_timeout_in_minutes: (Optional) Minutes to retry fetching the
 subscription ARN before marking it a
 failure (http/https only). Default 1.
 - endpoint_auto_confirms: (Optional) Whether the endpoint
 auto-confirms the subscription (e.g. a
 PagerDuty-style HTTPS endpoint). Default
 false. For http/https/email/email-json
 endpoints that do NOT auto-confirm,
 Terraform creates the subscription in
 PendingConfirmation state and cannot
 complete the handshake -- see the
 README's AWS Prerequisites section.
EOT
 type = map(object({
 protocol = string
 endpoint = string
 subscription_role_arn = optional(string)
 raw_message_delivery = optional(bool, false)
 filter_policy = optional(string)
 filter_policy_scope = optional(string)
 redrive_policy = optional(string)
 replay_policy = optional(string)
 delivery_policy = optional(string)
 confirmation_timeout_in_minutes = optional(number, 1)
 endpoint_auto_confirms = optional(bool, false)
 }))
 default = {}

 validation {
 condition = alltrue([
 for k, v in var.subscriptions: contains(["sqs", "sms", "lambda", "firehose", "application", "email", "email-json", "http", "https"],
 v.protocol)
 ])
 error_message = "Every subscriptions[*].protocol must be one of: sqs, sms, lambda, firehose, application, email, email-json, http, https."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.protocol != "firehose" || v.subscription_role_arn != null])
 error_message = "subscriptions[*].subscription_role_arn is required when protocol = \"firehose\" (SNS must assume this role to publish to the Kinesis Data Firehose delivery stream)."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.filter_policy_scope == null || contains(["MessageAttributes", "MessageBody"], v.filter_policy_scope)])
 error_message = "subscriptions[*].filter_policy_scope must be \"MessageAttributes\", \"MessageBody\", or null."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.filter_policy == null || can(jsondecode(v.filter_policy))])
 error_message = "subscriptions[*].filter_policy must be valid JSON, or null."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.redrive_policy == null || can(jsondecode(v.redrive_policy))])
 error_message = "subscriptions[*].redrive_policy must be valid JSON, or null."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.replay_policy == null || can(jsondecode(v.replay_policy))])
 error_message = "subscriptions[*].replay_policy must be valid JSON, or null."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.delivery_policy == null || can(jsondecode(v.delivery_policy))])
 error_message = "subscriptions[*].delivery_policy must be valid JSON, or null."
 }

 validation {
 condition = alltrue([for k, v in var.subscriptions: v.confirmation_timeout_in_minutes == null || v.confirmation_timeout_in_minutes >= 1])
 error_message = "subscriptions[*].confirmation_timeout_in_minutes must be >= 1."
 }
}

###############################################################################
# Universal tail
###############################################################################

variable "tags" {
 description = <<EOT
A map of tags to assign to all taggable resources created by this module.
Only aws_sns_topic itself accepts a tags argument in this composite --
aws_sns_topic_policy, aws_sns_topic_subscription, and
aws_sns_topic_data_protection_policy do not support tags at all in the AWS
provider schema. These merge with provider-level default_tags; resource tags
win on key conflict. The computed tags_all output reflects the merged set on
the topic.
EOT
 type = map(string)
 default = {}
}
