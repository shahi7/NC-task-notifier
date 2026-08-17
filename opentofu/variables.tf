variable "host_id" {
  type    = string
  default = "z1"
}

variable "service_id" {
  type    = string
  default = "tb"
}

variable "stack_name" {
  type    = string
  default = "nc-taskbot"
}

variable "stack_root" {
  type    = string
  default = "/home/common/zeppelin1"
}

variable "compose_file" {
  type    = string
  default = "docker-compose.yml"
}

# null derives ${host_id}-${service_id}, matching the compose name key
variable "compose_project_name" {
  type    = string
  default = null
}

# only meaningful under the optional tailnet compose profile
variable "app_fqdn" {
  type    = string
  default = "nc-taskbot.m.onsaa.org"
}

variable "app_container_port" {
  type    = number
  default = 80
}

variable "vault_kv_path" {
  type    = string
  default = "nc-taskbot"
}

# per-delegation Discord user maps, read and written at runtime
variable "vault_user_map_kv_path" {
  type    = string
  default = "nc-taskbot/user_map_dc"
}

# bot and poller share one image built from app/
variable "image_build_context" {
  type    = string
  default = "app"
}

variable "auxiliary_vault_kv_paths" {
  type    = list(string)
  default = []
}

# the default stack needs Vault and the Nextcloud stack network, nothing else
variable "required_external_networks" {
  type    = list(string)
  default = ["vault_backend", "z1_nc_stack-internal"]
}

# only attached when the tailnet compose profile is started
variable "optional_external_networks" {
  type    = list(string)
  default = ["edge_proxy", "ts-net"]
}

# the sidecar is off by default; everything below applies to the tailnet profile
variable "ts_login_server" {
  type    = string
  default = "https://h.onsaa.org"
}

variable "ts_profile_enabled" {
  type    = bool
  default = false
}

# must not contain --login-server or --auth-key; the sidecar rejects them
variable "ts_bootstrap_extra_args" {
  type    = string
  default = ""
}

variable "ts_extra_args" {
  type    = string
  default = "--accept-dns=false"
}

variable "ts_reauth_control_file" {
  type    = string
  default = "runtime/control/tailscale-force-reauth"
}

variable "ts_authkey_secret_name" {
  type    = string
  default = "tailscale_authkey"
}

variable "ts_tagging_mode" {
  type    = string
  default = "server-side-after-bootstrap"
}

variable "ts_final_tags" {
  type    = list(string)
  default = ["tag:container", "tag:services"]
}

variable "service_bootstrap_required" {
  type    = bool
  default = false
}

variable "service_bootstrap_artifacts" {
  type    = list(string)
  default = []
}

variable "dependent_vault_kv_paths" {
  type    = list(string)
  default = []
}

variable "labels" {
  type    = map(string)
  default = {}
}
