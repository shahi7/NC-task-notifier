pid_file = "/tmp/vault.pid"

vault {
  address = "http://vault:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/vault/role_id"
      secret_id_file_path = "/vault/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/tmp/vault-token"
    }
  }
}

cache {
  use_auto_auth_token = true
}

template {
  source      = "/vault/templates/discord_bot_token.ctmpl"
  destination = "/shared-secrets/discord_bot_token"
}

template {
  source      = "/vault/templates/nextcloud_user.ctmpl"
  destination = "/shared-secrets/nextcloud_user"
}

template {
  source      = "/vault/templates/nextcloud_pass.ctmpl"
  destination = "/shared-secrets/nextcloud_pass"
}

template {
  source      = "/vault/templates/nextcloud_base_url.ctmpl"
  destination = "/shared-secrets/nextcloud_base_url"
}

template {
  source      = "/vault/templates/signal_url.ctmpl"
  destination = "/shared-secrets/signal_url"
}

template {
  source      = "/vault/templates/signal_url_get.ctmpl"
  destination = "/shared-secrets/signal_url_get"
}

template {
  source      = "/vault/templates/signal_sender.ctmpl"
  destination = "/shared-secrets/signal_sender"
}

template {
  source      = "/vault/templates/user_map_dc.ctmpl"
  destination = "/shared-secrets/user_map_dc"
}

template {
  source      = "/vault/templates/user_map_signal.ctmpl"
  destination = "/shared-secrets/user_map_signal"
}

template {
  source      = "/vault/templates/delegator_discord_id.ctmpl"
  destination = "/shared-secrets/delegator_discord_id"
}

template {
  source      = "/vault/templates/vault_admin_token.ctmpl"
  destination = "/shared-secrets/vault_admin_token"
}

template {
  source      = "/vault/templates/calendar_name.ctmpl"
  destination = "/shared-secrets/calendar_name"
}

template {
  source      = "/vault/templates/calendar_url.ctmpl"
  destination = "/shared-secrets/calendar_url"
}

template {
  source      = "/vault/templates/delegations_json.ctmpl"
  destination = "/shared-secrets/delegations_json"
}