# tf-mod-aws-sns — SCOPE

Composite **app-integration** module for a secure-by-default Amazon SNS topic.
It owns the topic and its directly-attached sub-resources — access policy,
subscriptions, and an optional data-protection policy — so a single module
call yields an encrypted, owner-locked-down pub/sub topic ready to fan out to
SQS queues, Lambda functions, HTTPS endpoints, email, SMS, or mobile push,
with clean `for_each`-driven subscription management.

- **Module type:** Composite (app_integration — Phase 2)
- **Primary resource (keystone):** `aws_sns_topic.this`

## In-scope resources

The module manages **all** of the following (allow-list):

- `aws_sns_topic` — keystone (standard or FIFO)
- `aws_sns_topic_policy` — topic access policy (owner-only default; caller-supplied JSON to override)
- `aws_sns_topic_subscription` — `for_each` over `map(object(...))` keyed by a caller-chosen stable name
- `aws_sns_topic_data_protection_policy` — optional PII detection/masking policy (off by default)

## Out-of-scope resources (consumed by reference)

Referenced by `arn`/`id`, never created here:

- KMS CMK for SSE-KMS — supplied by `tf-mod-aws-kms` via `kms_key_arn`/`kms_master_key_id`
  (optional; `null` default uses the AWS-managed `alias/aws/sns` key). The CMK's
  **key policy** (not this module's IAM identity) must grant the publishing/
  subscribing principals `kms:Decrypt` / `kms:GenerateDataKey` — see Required
  IAM permissions below.
- SQS subscription endpoints — queue `arn` from `tf-mod-aws-sqs`. This module
  does not create or modify the queue's redrive policy or queue policy; the
  caller (or `tf-mod-aws-sqs`) must grant the topic `sqs:SendMessage` on the
  queue policy.
- Lambda subscription endpoints — function `arn` from a **not-yet-authored**
  `tf-mod-aws-lambda` (Phase 7 in the roadmap). Wired by reference only; no
  dependency on that module exists yet. The caller is responsible for the
  Lambda resource-based policy granting `sns.amazonaws.com` `lambda:InvokeFunction`.
- Kinesis Data Firehose subscription endpoints — delivery stream `arn` from
  `tf-mod-aws-kinesis-firehose` (Phase 2 sibling), plus a `subscription_role_arn`
  (IAM role `arn` from `tf-mod-aws-iam-role`) that SNS assumes to publish to
  Firehose — required by the provider whenever `protocol = "firehose"`.
- Literal HTTP(S) / email / email-json / SMS / mobile-application endpoints —
  supplied directly by the caller as plain strings (URL, address, phone number,
  or platform-application-endpoint ARN). No module dependency.

## Consumes

Primarily a **standalone-with-references** module — it originates the topic
but wires several optional inputs by ARN from sibling modules.

| Input | Type | Source module |
|---|---|---|
| `kms_key_arn` (mapped to `kms_master_key_id`) | `string`, optional, default `null` | `tf-mod-aws-kms` (or literal `"alias/aws/sns"` / AWS key id) |
| Subscription `endpoint` (protocol `sqs`) | `string` (queue ARN) | `tf-mod-aws-sqs` |
| Subscription `endpoint` (protocol `lambda`) | `string` (function ARN) | `tf-mod-aws-lambda` — **not yet authored (Phase 7)**, reference-only today |
| Subscription `endpoint` (protocol `firehose`) + `subscription_role_arn` | `string` (stream ARN) + `string` (role ARN) | `tf-mod-aws-kinesis-firehose` + `tf-mod-aws-iam-role` |
| Subscription `endpoint` (protocol `http`/`https`/`email`/`email-json`/`sms`/`application`) | `string` (literal) | Caller-supplied, no module dependency |
| Custom topic access policy JSON | `string`, optional | Caller-authored `data.aws_iam_policy_document`, or `tf-mod-aws-iam-policy` pattern reused inline |

## Required IAM permissions

Least-privilege actions the Terraform identity needs:

| Action | Required for |
|---|---|
| `sns:CreateTopic`, `sns:DeleteTopic`, `sns:GetTopicAttributes`, `sns:SetTopicAttributes` | Topic lifecycle (name, display name, delivery policy, KMS key id, FIFO settings) |
| `sns:TagResource`, `sns:UntagResource`, `sns:ListTagsForResource` | Tagging |
| `sns:Subscribe`, `sns:Unsubscribe`, `sns:ListSubscriptionsByTopic`, `sns:ConfirmSubscription` | Subscription lifecycle |
| `sns:AddPermission`, `sns:RemovePermission` | Topic access policy (`aws_sns_topic_policy`) |
| `sns:PutDataProtectionPolicy`, `sns:GetDataProtectionPolicy` | Optional data-protection policy |
| `kms:DescribeKey` | Validating a caller-supplied CMK id/alias at plan/apply time |
| `iam:PassRole` | Only when a `firehose` subscription's `subscription_role_arn` must be passed to SNS |

> **KMS key-policy note:** `kms:Decrypt`, `kms:GenerateDataKey*`, and
> `kms:Encrypt` for a **customer-managed key** are granted on the **KMS key's
> resource policy** (authored by `tf-mod-aws-kms`), not on this module's
> caller identity. This module only needs `kms:DescribeKey` to validate the
> key reference. Forgetting to update the CMK's key policy to trust
> `sns.amazonaws.com` (and the publishing/subscribing principals) is the most
> common cause of "KMS.AccessDeniedException" at publish time.

## AWS Prerequisites

- **No service-linked role** required for SNS.
- **FIFO topics:** the topic `name` must end in `.fifo`; `fifo_topic = true` is
  required and immutable after creation (standard ↔ FIFO requires replacement).
  FIFO topics cannot deliver to `http`/`https`/`email`/`email-json`/`sms`/
  `application` endpoints — only `sqs` and `firehose` are supported ordering-
  preserving targets. `content_based_deduplication` is optional and mutable.
- **Cross-account / HTTP(S) / email / email-json subscriptions require manual
  confirmation outside Terraform's control** (unless `endpoint_auto_confirms`
  is true, e.g. PagerDuty-style endpoints). Terraform creates the subscription
  in `PendingConfirmation` state; the `pending_confirmation` attribute on
  `aws_sns_topic_subscription` reports this. Terraform **cannot** delete/
  unsubscribe an unconfirmed subscription — `destroy` removes it from state
  only, leaving the live AWS subscription behind until manually unsubscribed
  or the parent topic is deleted (topic deletion cascades to all subscriptions).
- **Topic policy changes are eventually consistent** — a `terraform apply`
  that both creates the topic and attaches a policy can occasionally need a
  second apply to observe consistent `GetTopicAttributes` reads immediately
  after `AddPermission`.
- **Cross-region subscriptions:** if the SNS topic and its SQS/Lambda/Firehose
  endpoint live in different regions, the `aws_sns_topic_subscription` must
  use a provider configured for the **topic's** region, not the endpoint's.
- **Quotas:** 100,000 topics per account (soft), 12,500,000 subscriptions per
  topic (soft), 10MB max message size (with extended-client-library patterns
  for larger payloads via S3, out of scope for this module).

## Emits

| Output | Description | Consumed by |
|---|---|---|
| `id` | Topic ARN — **NOTE:** for `aws_sns_topic`, `id` and `arn` are the identical value (AWS quirk; SNS has no separate short id). Emitted anyway per house rule. | Any module referencing the topic generically |
| `arn` | Topic ARN (`arn:aws:sns:<region>:<account-id>:<name>`) — cross-resource reference type | `tf-mod-aws-sqs` (queue policy `Condition.ArnEquals`), `tf-mod-aws-iam-policy` (publish/subscribe permissions), `tf-mod-aws-cloudwatch-log-group` (alarm actions), `tf-mod-aws-lambda` (event source / DLQ target, once authored) |
| `name` | Topic name | Tagging, monitoring, dashboards, naming-convention audits |
| `owner` | AWS account id of the topic owner | Cross-account policy authoring, audit |
| `beginning_archive_time` | Oldest replayable timestamp for a FIFO topic with `archive_policy_json` set; empty otherwise | FIFO replay tooling |
| `topic_policy_attached` | `true` when a custom `aws_sns_topic_policy` was created (i.e. `topic_policy_json` supplied) | Audit / drift checks confirming owner-only default is or isn't in force |
| `data_protection_policy_enabled` | `true` when `aws_sns_topic_data_protection_policy` was created | Audit / compliance reporting |
| `tags_all` | Computed merge of resource tags over provider `default_tags` | Governance/audit |
| `subscription_arns` | Map (keyed by the caller's subscription key) of subscription ARNs | Audit, `pending_confirmation` follow-up tooling |
| `subscription_pending_confirmation` | Map (keyed by the caller's subscription key) of `pending_confirmation` booleans | Ops runbooks that need to chase down manual confirmations |
| `subscription_confirmation_was_authenticated` | Map (keyed by the caller's subscription key) of `confirmation_was_authenticated` booleans | Security audit of subscription confirmation handshakes |
| `subscription_owner_ids` | Map (keyed by the caller's subscription key) of the AWS account id owning each subscription | Cross-account subscription audit |

## Provider gotchas

- **`name` is effectively immutable.** SNS does not support renaming a topic;
  changing `name` forces the provider to destroy and recreate `aws_sns_topic.this`
  (and, transitively, every subscription and policy attached to it, since they
  reference the topic ARN). Treat `name` as force-new in practice even though
  the provider docs describe it as an ordinary optional argument.
- **`fifo_topic` is immutable.** Standard-to-FIFO (or the reverse) is not an
  in-place update; it requires replacement. Decide FIFO vs. standard at design
  time — this is not a toggle to flip later without a subscriber migration.
- **`content_based_deduplication` is NOT force-new** — it can be flipped
  in-place on an existing FIFO topic.
- **`id` and `arn` are the same value.** Unlike most AWS resources, SNS topics
  have no separate resource identifier — `aws_sns_topic.this.id` and
  `aws_sns_topic.this.arn` both return the full topic ARN. Both are still
  emitted as distinct outputs to satisfy the house `id` + `arn` convention and
  keep this module's output contract consistent with every other module.
- **Subscription confirmation is a Terraform blind spot.** For `http`, `https`,
  `email`, and `email-json` protocols (without `endpoint_auto_confirms`), the
  subscription handshake happens outside Terraform. `terraform apply` succeeds
  and creates a `PendingConfirmation` subscription; nothing in Terraform
  completes that confirmation. Document this loudly for callers who expect a
  fully-automated pipeline.
- **`firehose` protocol requires `subscription_role_arn`.** The provider
  enforces this as a conditionally-required argument; omitting it when
  `protocol = "firehose"` is a plan-time error.
- **Topic policy is a separate resource, not an attribute.** `aws_sns_topic_policy`
  attaches independently of `aws_sns_topic`; destroying just the policy resource
  reverts the topic to the SNS default policy (owner-only), it does not delete
  the topic.
- **Destroy ordering:** deleting the topic cascades and deletes all attached
  subscriptions server-side, but Terraform still tracks subscriptions as
  separate state entries — expect Terraform to attempt (and no-op) DeleteSubscription
  calls against already-gone subscriptions when destroying the whole module in
  one pass. This is benign but can be surprising in plan output.
- **`tags` vs `tags_all`.** `var.tags` flows to `aws_sns_topic.this.tags` only
  (the other three resources in this composite — policy, subscription, data
  protection policy — do not accept a `tags` argument at all in the AWS
  provider schema); `tags_all` is the computed merge of topic tags over
  provider `default_tags` (resource tags win on conflict).

## Secure-by-default decisions

| Posture | Default | Opt-out |
|---|---|---|
| Encryption at rest (SSE-KMS) | **Enabled** — `kms_master_key_id` defaults to the AWS-managed key alias `"alias/aws/sns"` when the caller supplies no `kms_key_arn` | Pass `enable_encryption = false` to omit `kms_master_key_id` entirely (unencrypted topic) — requires a documented exception for NPI-adjacent workloads |
| Topic access policy | **Owner-account-only** publish/subscribe/manage (no public principals) unless the caller supplies a custom `topic_policy_json` | Supply `topic_policy_json` with broader principals (e.g. cross-account `sqs:SendMessage` grants) — caller's responsibility to scope tightly |
| Data protection policy (PII detection/masking) | **Off** by default (`data_protection_policy_json = null`) — no additional inline-inspection overhead unless opted in | Supply `data_protection_policy_json` to enable PII `Deny`/`Deidentify`/`Audit` statements |
| FIFO ordering / dedup | Standard topic by default (`fifo_topic = false`) | Set `fifo_topic = true` (name must end `.fifo`); `content_based_deduplication` opt-in |
| Delivery status logging | Off by default (`delivery_status_logging = {}`) — avoids requiring a CloudWatch Logs IAM role for every protocol by default | Add an entry keyed by protocol (`application`/`http`/`lambda`/`sqs`/`firehose`) to `delivery_status_logging` with `success_feedback_role_arn` / `failure_feedback_role_arn` / `success_feedback_sample_rate` to enable per-protocol delivery status logging to CloudWatch Logs |

## Design decisions

- Subscriptions are modeled as `map(object({...optional()}))` keyed by a
  caller-chosen stable name (e.g. `"billing-queue"`, `"ops-email"`) rather than
  a list, so adding/removing one subscription does not perturb others under
  `for_each` (no `count`-style index shifting).
- The topic access policy is exposed as a single optional JSON string
  (`topic_policy_json`) rather than a structured object, mirroring how AWS
  itself treats SNS policies as opaque JSON documents best authored via
  `data.aws_iam_policy_document` in the caller's root module — this keeps the
  module's variable surface simple while still allowing full policy control.
  When `null` (default), the module does not create `aws_sns_topic_policy` at
  all, leaving SNS's built-in owner-only default policy in force.
- The data protection policy is optional and off by default: it is a
  distinct, separately-billed inspection feature (PII detection/masking on
  message bodies) that adds processing overhead, so it is opt-in rather than
  assumed for every topic.
- Lambda and Kinesis Firehose subscription targets are documented as
  reference-only inputs even though `tf-mod-aws-lambda` does not exist yet
  (Phase 7) — the subscription `object()` schema accepts any ARN string today
  so this module does not need to change when that module ships later.
- `kms_master_key_id` accepts either a full CMK ARN/id (from `tf-mod-aws-kms`)
  or an alias string, matching the provider's own flexibility, rather than
  forcing callers through a single input shape.
- The keystone also exposes the remaining `aws_sns_topic` topic-level
  arguments confirmed against the live v6.53.0 schema during authoring —
  `display_name`, `delivery_policy_json` (topic-level HTTP retry policy),
  `signature_version` (default `"1"`, matching the AWS default), `tracing_config`
  (default `"PassThrough"`, matching the AWS default), and FIFO-only
  `fifo_throughput_scope` / `archive_policy_json` — since they are arguments on
  the in-scope keystone resource itself, not separate resources requiring a
  scope decision.
- Per-protocol delivery status logging (`application_success_feedback_role_arn`
  and its 14 sibling arguments on `aws_sns_topic`) is modeled as a single
  `delivery_status_logging` variable — `map(object({success_feedback_role_arn,
  success_feedback_sample_rate, failure_feedback_role_arn}))` keyed by protocol
  name (`application`/`http`/`lambda`/`sqs`/`firehose`) — rather than 15
  individual flat variables, so the topic-level resource block stays readable
  and callers only declare the protocols they actually want logged. Off by
  default (empty map) per the secure-by-default decision below.
- Neither `aws_sns_topic` nor any AWS API surfaces a `timeouts {}` block for
  SNS resources (confirmed against the live v6.53.0 provider schema and
  documentation during authoring) — this module intentionally has no
  `timeouts` variable, consistent with `tf-mod-aws-kms`'s precedent of
  omitting it when the underlying resource doesn't support one.
- `name_prefix` (an alternative to `name` that lets AWS auto-generate a unique
  suffix) is deliberately NOT exposed — Casey's governance/tagging conventions
  depend on deterministic, caller-chosen resource names, so this module only
  accepts `name`.
