variable "host_id" {
  type    = string
  default = "p1"
}

variable "service_id" {
  type    = string
  default = "svc"
}

variable "stack_name" {
  type    = string
  default = "example-service"
}

variable "stack_root" {
  type    = string
  default = "/home/common/stacks"
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

variable "app_fqdn" {
  type    = string
  default = "example.m.onsaa.org"
}

variable "app_container_port" {
  type    = number
  default = 8080
}

variable "vault_kv_path" {
  type    = string
  default = "example-service"
}

variable "auxiliary_vault_kv_paths" {
  type    = list(string)
  default = []
}

variable "required_external_networks" {
  type    = list(string)
  default = ["edge_proxy", "ts-net", "vault_backend"]
}

variable "ts_login_server" {
  type    = string
  default = "https://h.onsaa.org"
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
