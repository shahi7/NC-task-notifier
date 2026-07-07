pid_file = "/tmp/vault-agent.pid"

vault {
  address = "http://vault:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/vault-agent/role_id"
      secret_id_file_path = "/vault-agent/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/tmp/vault-agent-token"
    }
  }
}

cache {
  use_auto_auth_token = true
}

template {
  source      = "/vault-agent/templates/discord_bot_token.ctmpl"
  destination = "/shared-secrets/discord_bot_token"
}

template {
  source      = "/vault-agent/templates/nextcloud_user.ctmpl"
  destination = "/shared-secrets/nextcloud_user"
}

template {
  source      = "/vault-agent/templates/nextcloud_pass.ctmpl"
  destination = "/shared-secrets/nextcloud_pass"
}

template {
  source      = "/vault-agent/templates/nextcloud_base_url.ctmpl"
  destination = "/shared-secrets/nextcloud_base_url"
}

template {
  source      = "/vault-agent/templates/signal_url.ctmpl"
  destination = "/shared-secrets/signal_url"
}

template {
  source      = "/vault-agent/templates/signal_sender.ctmpl"
  destination = "/shared-secrets/signal_sender"
}