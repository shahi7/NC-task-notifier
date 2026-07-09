# policy for bot read/write access to user map
path "secret/data/taskbot/config/user_map_dc/*" {
  capabilities = ["read", "update"]
}