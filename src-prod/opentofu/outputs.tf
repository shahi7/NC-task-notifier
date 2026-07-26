output "compose_project_name" {
  value = local.compose_project_name
}

output "stack_path" {
  value = local.stack_path
}

output "standard_paths" {
  value = local.standard_paths
}

output "required_external_networks" {
  value = var.required_external_networks
}

output "network_intent" {
  value = local.network_intent
}

output "tailscale_recovery_intent" {
  value = local.network_intent.tailscale
}

output "service_bootstrap_intent" {
  value = local.network_intent.bootstrap
}

output "vault_kv_data_path" {
  value = local.vault_kv_data_path
}

output "auxiliary_vault_kv_data_paths" {
  value = local.auxiliary_vault_paths
}

output "metadata" {
  value = local.metadata
}
