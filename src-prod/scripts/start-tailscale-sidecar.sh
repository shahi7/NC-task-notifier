#!/usr/bin/env sh
set -eu

AUTHKEY_FILE="${TS_AUTHKEY_FILE:-/run/stack-secrets/tailscale_authkey}"
STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
SOCKET_DIR="${TS_SOCKET_DIR:-/run/tailscale}"
SOCKET_PATH="${SOCKET_DIR}/tailscaled.sock"
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
TS_BOOTSTRAP_EXTRA_ARGS="${TS_BOOTSTRAP_EXTRA_ARGS:-}"
TS_FORCE_REAUTH="${TS_FORCE_REAUTH:-0}"
TS_RESET_ON_REAUTH="${TS_RESET_ON_REAUTH:-1}"
TS_SERVE_ENABLED="${TS_SERVE_ENABLED:-0}"
TS_SERVE_TARGET="${TS_SERVE_TARGET:-}"
TS_UP_TIMEOUT_SECONDS="${TS_UP_TIMEOUT_SECONDS:-90}"
TS_REAUTH_SENTINEL_FILE="${TS_REAUTH_SENTINEL_FILE:-/run/stack-control/tailscale-force-reauth}"

case " ${TS_EXTRA_ARGS} ${TS_BOOTSTRAP_EXTRA_ARGS} " in
  *" --login-server"*)
    echo "Do not put --login-server in TS_EXTRA_ARGS or TS_BOOTSTRAP_EXTRA_ARGS; set TS_LOGIN_SERVER instead." >&2
    exit 2
    ;;
  *" --auth-key"*)
    echo "Do not put --auth-key in TS_EXTRA_ARGS or TS_BOOTSTRAP_EXTRA_ARGS; set TS_AUTHKEY_FILE instead." >&2
    exit 2
    ;;
esac

args_include_flag() {
  args="$1"
  flag="$2"
  case " $args " in
    *" ${flag}"*)
      return 0
      ;;
  esac
  return 1
}

mkdir -p "$STATE_DIR" "$SOCKET_DIR" /tmp

tailscaled \
  --state="${STATE_DIR}/tailscaled.state" \
  --socket="$SOCKET_PATH" &

TS_PID="$!"

cleanup() {
  kill "$TS_PID" 2>/dev/null || true
  wait "$TS_PID" 2>/dev/null || true
}
trap cleanup INT TERM

wait_for_local_api() {
  i=0
  while [ "$i" -lt 60 ]; do
    if tailscale --socket="$SOCKET_PATH" status >/dev/null 2>&1; then
      return 0
    fi
    # logged-out sidecars have a socket before `status` succeeds; socket is enough
    if [ -S "$SOCKET_PATH" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "tailscaled local API did not become ready within 60s" >&2
  return 1
}

wait_for_tailscale_running() {
  i=0
  while [ "$i" -lt "$TS_UP_TIMEOUT_SECONDS" ]; do
    status_json="$(tailscale --socket="$SOCKET_PATH" status --json 2>/dev/null || true)"

    if printf '%s' "$status_json" | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
      return 0
    fi
    if tailscale --socket="$SOCKET_PATH" ip -4 >/dev/null 2>&1; then
      return 0
    fi
    if printf '%s' "$status_json" | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"NeedsLogin"'; then
      echo "tailscale entered interactive login state; refusing sidecar startup" >&2
      return 1
    fi
    if printf '%s' "$status_json" | grep -Eq '"AuthURL"[[:space:]]*:[[:space:]]*"https://'; then
      echo "tailscale requested interactive auth URL; refusing sidecar startup" >&2
      return 1
    fi

    i=$((i + 1))
    sleep 1
  done

  echo "tailscale did not reach Running state within ${TS_UP_TIMEOUT_SECONDS}s" >&2
  printf '%s\n' "$status_json" >&2
  return 1
}

tailscale_has_running_state() {
  status_json="$(tailscale --socket="$SOCKET_PATH" status --json 2>/dev/null || true)"
  printf '%s' "$status_json" | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'
}

wait_for_local_api

force_reauth=0
if [ "$TS_FORCE_REAUTH" = "1" ]; then
  force_reauth=1
fi
if [ -f "$TS_REAUTH_SENTINEL_FILE" ]; then
  force_reauth=1
fi

if [ "$force_reauth" = "1" ]; then
  tailscale --socket="$SOCKET_PATH" logout >/dev/null 2>&1 || true
fi

if [ "$force_reauth" = "1" ] || ! tailscale_has_running_state; then
  if [ ! -s "$AUTHKEY_FILE" ]; then
    echo "missing Tailscale auth key at $AUTHKEY_FILE and no reusable state is available" >&2
    exit 1
  fi

  up_args="--hostname=${TS_HOSTNAME}"
  if [ -n "$TS_LOGIN_SERVER" ]; then
    up_args="$up_args --login-server=${TS_LOGIN_SERVER}"
  fi
  if [ -n "$TS_EXTRA_ARGS" ]; then
    up_args="$up_args $TS_EXTRA_ARGS"
  fi

  # clear remembered tags unless bootstrap args intentionally advertise them
  if ! args_include_flag "$TS_EXTRA_ARGS" "--advertise-tags" && \
     ! args_include_flag "$TS_BOOTSTRAP_EXTRA_ARGS" "--advertise-tags"; then
    up_args="$up_args --advertise-tags="
  fi

  if [ -n "$TS_BOOTSTRAP_EXTRA_ARGS" ]; then
    up_args="$up_args $TS_BOOTSTRAP_EXTRA_ARGS"
  fi
  if [ "$force_reauth" = "1" ] && [ "$TS_RESET_ON_REAUTH" = "1" ]; then
    up_args="$up_args --reset"
  fi
  if [ "$force_reauth" = "1" ]; then
    up_args="$up_args --force-reauth"
  fi

  # shellcheck disable=SC2086
  tailscale --socket="$SOCKET_PATH" up \
    --auth-key="file:${AUTHKEY_FILE}" \
    $up_args

  wait_for_tailscale_running
  if [ -f "$TS_REAUTH_SENTINEL_FILE" ]; then
    rm -f "$TS_REAUTH_SENTINEL_FILE"
  fi
else
  echo "existing Tailscale state is valid; create ${TS_REAUTH_SENTINEL_FILE} to force one-shot reauth"
fi

if [ "$TS_SERVE_ENABLED" = "1" ]; then
  if [ -z "$TS_SERVE_TARGET" ]; then
    echo "TS_SERVE_ENABLED=1 requires TS_SERVE_TARGET" >&2
    exit 1
  fi
  tailscale --socket="$SOCKET_PATH" serve --bg "$TS_SERVE_TARGET"
fi

echo "tailscale sidecar is running"
wait "$TS_PID"
