locals {
  stack_path            = "${trimsuffix(var.stack_root, "/")}/${var.stack_name}"
  compose_project_name  = coalesce(var.compose_project_name, "${var.host_id}-${var.service_id}")
  vault_kv_data_path    = var.vault_kv_path == null ? null : "kv/data/${var.vault_kv_path}"
  auxiliary_vault_paths = [for path in var.auxiliary_vault_kv_paths : "kv/data/${path}"]
  standard_paths = {
    root           = local.stack_path
    compose        = "${local.stack_path}/${var.compose_file}"
    opentofu       = "${local.stack_path}/opentofu"
    config         = "${local.stack_path}/config"
    data           = "${local.stack_path}/data"
    runtime        = "${local.stack_path}/runtime"
    control        = "${local.stack_path}/runtime/control"
    secrets        = "${local.stack_path}/runtime/secrets"
    vault_auth     = "${local.stack_path}/runtime/vault-auth"
    backups        = "${local.stack_path}/backups"
    data_app       = "${local.stack_path}/data/app"
    data_tailscale = "${local.stack_path}/data/tailscale"
  }
  repo_layout = {
    backups = "${local.stack_path}/backups"
    config  = "${local.stack_path}/config"
    docs    = "${local.stack_path}/docs"
    hooks   = "${local.stack_path}/hooks"
    runtime = "${local.stack_path}/runtime"
    scripts = "${local.stack_path}/scripts"
    tools   = "${local.stack_path}/tools"
    vault   = "${local.stack_path}/vault"
  }
  network_intent = {
    app = {
      fqdn          = var.app_fqdn
      internal_port = var.app_container_port
    }
    vault = {
      primary    = local.vault_kv_data_path
      supporting = local.auxiliary_vault_paths
    }
    tailscale = {
      login_server         = var.ts_login_server
      extra_args           = var.ts_extra_args
      bootstrap_extra_args = var.ts_bootstrap_extra_args
      authkey_secret_name  = var.ts_authkey_secret_name
      reauth_control_file  = "${local.stack_path}/${var.ts_reauth_control_file}"
      tagging_mode         = var.ts_tagging_mode
      final_tags           = var.ts_final_tags
    }
    bootstrap = {
      required         = var.service_bootstrap_required
      artifacts        = var.service_bootstrap_artifacts
      dependent_vaults = var.dependent_vault_kv_paths
    }
    external_networks = var.required_external_networks
  }
  metadata = merge({
    host_id              = var.host_id
    service_id           = var.service_id
    stack_name           = var.stack_name
    stack_path           = local.stack_path
    compose_project_name = local.compose_project_name
    compose_file         = var.compose_file
    app_fqdn             = var.app_fqdn
    app_container_port   = var.app_container_port
    vault_kv_path        = var.vault_kv_path
    ts_login_server      = var.ts_login_server
    ts_authkey_secret    = var.ts_authkey_secret_name
    ts_tagging_mode      = var.ts_tagging_mode
    ts_final_tags        = join(",", var.ts_final_tags)
    ts_reauth_control    = var.ts_reauth_control_file
    service_bootstrap    = tostring(var.service_bootstrap_required)
    managed_by           = "opentofu-metadata-baseline"
  }, var.labels)
}
