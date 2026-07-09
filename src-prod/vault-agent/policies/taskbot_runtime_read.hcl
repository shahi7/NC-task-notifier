# policy for config read-only vars needed at runtime
path "secret/data/taskbot/runtime" {
  capabilities = ["read"]
}