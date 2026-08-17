exit_after_auth = false
pid_file = "/tmp/vault-agent.pid"

vault {
  # Rendered by scripts/start-vault-agent.sh before Vault Agent starts.
  address   = "$VAULT_ADDR"
  ca_cert   = "$VAULT_CACERT"
  namespace = "$VAULT_NAMESPACE"
}

auto_auth {
  method "approle" {
    mount_path = "auth/$APPROLE_MOUNT"

    config = {
      role_id_file_path = "/vault/auth/role_id"
      secret_id_file_path = "/vault/auth/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

}

template_config {
  # Static KV secrets are rechecked on this cadence.
  static_secret_render_interval = "$VAULT_STATIC_SECRET_RENDER_INTERVAL"
  exit_on_retry_failure = true
}

template {
  source      = "/vault/templates/ready.ctmpl"
  destination = "/vault/secrets/vault-agent/.vault-agent-ready"
  perms       = "0440"
}

template {
  source      = "/vault/templates/tailscale_authkey.ctmpl"
  destination = "/vault/secrets/ts-sidecar/tailscale_authkey"
  perms       = "0440"
}

template {
  source      = "/vault/templates/discord_bot_token.ctmpl"
  destination = "/vault/secrets/bot/discord_bot_token"
  perms       = "0440"
}

template {
  source      = "/vault/templates/nextcloud_user.ctmpl"
  destination = "/vault/secrets/bot/nextcloud_user"
  perms       = "0440"
}

template {
  source      = "/vault/templates/nextcloud_pass.ctmpl"
  destination = "/vault/secrets/bot/nextcloud_pass"
  perms       = "0440"
}

template {
  source      = "/vault/templates/signal_sender.ctmpl"
  destination = "/vault/secrets/bot/signal_sender"
  perms       = "0440"
}

template {
  source      = "/vault/templates/vault_bot_token.ctmpl"
  destination = "/vault/secrets/bot/vault_bot_token"
  perms       = "0440"
}

template {
  source      = "/vault/templates/delegations_json.ctmpl"
  destination = "/vault/secrets/bot/delegations_json"
  perms       = "0440"
}

template {
  source      = "/vault/templates/nextcloud_user.ctmpl"
  destination = "/vault/secrets/poller/nextcloud_user"
  perms       = "0440"
}

# fix 2026-07-27: poller needs the bot token to read user maps.
template {
  source      = "/vault/templates/vault_bot_token.ctmpl"
  destination = "/vault/secrets/poller/vault_bot_token"
  perms       = "0440"
}

template {
  source      = "/vault/templates/nextcloud_pass.ctmpl"
  destination = "/vault/secrets/poller/nextcloud_pass"
  perms       = "0440"
}

template {
  source      = "/vault/templates/signal_sender.ctmpl"
  destination = "/vault/secrets/poller/signal_sender"
  perms       = "0440"
}

template {
  source      = "/vault/templates/delegations_json.ctmpl"
  destination = "/vault/secrets/poller/delegations_json"
  perms       = "0440"
}
