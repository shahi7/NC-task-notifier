#!/usr/bin/env bash
set -Eeuo pipefail

: "${HEADSCALE_CONTAINER:=headscale}"
: "${TS_HOSTNAME:=example-sidecar}"
: "${TS_FINAL_TAGS:=tag:container,tag:services}"

usage() {
  cat <<'EOF'
Usage: ./scripts/retag-headscale-node.sh

Find the current Headscale node for TS_HOSTNAME and apply TS_FINAL_TAGS with
`headscale nodes tag --force`.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd docker
need_cmd jq

docker ps --format '{{.Names}}' | grep -Fxq "$HEADSCALE_CONTAINER" || {
  echo "Headscale container not running: $HEADSCALE_CONTAINER" >&2
  exit 1
}

nodes_json="$(docker exec "$HEADSCALE_CONTAINER" headscale nodes list -o json)"
node_id="$(
  printf '%s' "$nodes_json" | jq -r --arg host "$TS_HOSTNAME" '
    def node_name:
      .given_name // .givenName // .hostname // .name // "";
    def online_score:
      if (.online // false) then 1 else 0 end;
    def last_seen_score:
      .last_seen.seconds // .lastSeen.seconds // -62135596800;
    [
      .[]
      | select(
          node_name == $host
          or (.name // "" | startswith($host))
          or (.hostname // "" == $host)
          or (.hostinfo.hostname // "" == $host)
          or (.Hostinfo.Hostname // "" == $host)
        )
    ]
    | sort_by(online_score, last_seen_score, (.id // -1))
    | last
    | .id // empty
  ' | sed -n '1p'
)"

[ -n "$node_id" ] || {
  echo "Unable to find a Headscale node matching TS_HOSTNAME=${TS_HOSTNAME}" >&2
  exit 1
}

IFS=',' read -r -a tags <<< "$TS_FINAL_TAGS"
cmd=(docker exec "$HEADSCALE_CONTAINER" headscale nodes tag -i "$node_id")
for tag in "${tags[@]}"; do
  tag="$(printf '%s' "$tag" | xargs)"
  [ -n "$tag" ] || continue
  cmd+=(-t "$tag")
done
cmd+=(--force)

"${cmd[@]}" >/dev/null
echo "Retagged Headscale node ${node_id} for ${TS_HOSTNAME} with ${TS_FINAL_TAGS}."
