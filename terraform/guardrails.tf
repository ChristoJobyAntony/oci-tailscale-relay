# Optional tenancy-wide guardrails for an account that must stay inside OCI's
# Always Free allowances. Enabled per deployment with enable_free_tier_guardrails.
#
# Two layers:
#   1. A quota policy: hard caps the control plane enforces at creation time, so
#      nothing larger than the free allowance can be launched, even by hand.
#   2. A whole-tenancy budget with actual and forecast alerts: a tripwire for
#      anything quotas cannot cap (data transfer, services without quotas).
#
# Quotas only gate new resources; anything already above a cap keeps running.
# Both resources must be created in the tenancy's home region.

locals {
  free_tier_quota_statements = [
    # Compute: only the Always Free shapes, at the Always Free size. A1 is in
    # OCPUs and GB; the AMD micro is capped by both its core and instance count.
    "zero compute-core quotas in tenancy",
    # A1 has both an AD-scoped and a regional quota; a launch is checked against both.
    "set compute-core quota standard-a1-core-count to ${var.free_tier_a1_ocpus} in tenancy",
    "set compute-core quota standard-a1-core-regional-count to ${var.free_tier_a1_ocpus} in tenancy",
    "set compute-core quota standard-e2-micro-core-count to ${var.free_tier_micro_instances} in tenancy",
    "zero compute-memory quotas in tenancy",
    "set compute-memory quota standard-a1-memory-count to ${var.free_tier_a1_memory_gbs} in tenancy",
    "set compute-memory quota standard-a1-memory-regional-count to ${var.free_tier_a1_memory_gbs} in tenancy",
    "set compute quota vm-standard-e2-1-micro-count to ${var.free_tier_micro_instances} in tenancy",
    # Storage: the Always Free pool (boot and block volumes combined) and its backups.
    "set block-storage quota total-storage-gb to ${var.free_tier_block_storage_gb} in tenancy",
    "set block-storage quota backup-count to 5 in tenancy",
    "set object-storage quota storage-bytes to ${var.free_tier_object_storage_gb * 1024 * 1024 * 1024} in tenancy",
    # Services this stack never uses and that bill from the first unit.
    "zero database quotas in tenancy",
    "zero load-balancer quotas in tenancy",
    "zero nosql quotas in tenancy",
    "zero streaming quotas in tenancy",
    "zero analytics quotas in tenancy",
    "zero integration quotas in tenancy",
    "zero container-engine quotas in tenancy",
    "zero network-firewall quotas in tenancy",
    "zero compute-management quotas in tenancy",
    "zero auto-scaling quotas in tenancy",
  ]
}

resource "oci_limits_quota" "free_tier" {
  count = var.enable_free_tier_guardrails ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "always-free-guardrails"
  description    = "Caps the tenancy at the Always Free allowances so nothing billable can be created."
  statements     = concat(local.free_tier_quota_statements, var.free_tier_extra_quota_statements)
  freeform_tags  = local.common_tags
}

resource "oci_budget_budget" "tenancy" {
  count = var.enable_free_tier_guardrails ? 1 : 0

  compartment_id = var.tenancy_ocid
  amount         = var.tenancy_budget_amount
  reset_period   = "MONTHLY"
  display_name   = "tenancy-always-free-budget"
  description    = "Whole-tenancy spend guardrail; any charge means something left the Always Free tier."
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
  freeform_tags  = local.common_tags
}

resource "oci_budget_alert_rule" "tenancy_actual" {
  count = var.enable_free_tier_guardrails ? 1 : 0

  budget_id      = oci_budget_budget.tenancy[0].id
  display_name   = "tenancy-actual-spend"
  description    = "Actual spend reached the whole-tenancy budget."
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_recipients
  message        = format("OCI tenancy spend reached %v (tenancy currency): something is outside the Always Free tier.", var.tenancy_budget_amount)
}

resource "oci_budget_alert_rule" "tenancy_forecast" {
  count = var.enable_free_tier_guardrails ? 1 : 0

  budget_id      = oci_budget_budget.tenancy[0].id
  display_name   = "tenancy-forecast-spend"
  description    = "Forecast spend for the month exceeds the whole-tenancy budget."
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_recipients
  message        = format("OCI tenancy is forecast to exceed %v (tenancy currency) this month: check Cost Analysis.", var.tenancy_budget_amount)
}
