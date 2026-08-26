import json
import os
from pathlib import Path

import requests

from helpers import get_secret

# vault helper functions, for updating user map slash command
VAULT_ADDR = os.getenv("VAULT_ADDR")
VAULT_BOT_TOKEN = get_secret("VAULT_BOT_TOKEN")  # new, narrow token
LOCAL_DEV = os.getenv("LOCAL_DEV", "").strip() == "1"  # remove; for local testing

# fix 2026-07-27: was the "secret/" mount, which this vault does not have
USER_MAP_PATH = os.getenv(
    "VAULT_USER_MAP_PATH", "kv/data/nc-taskbot/user_map_dc"
)


# remove; for local testing
def local_user_map_file(delegation_id: str) -> Path:
    env_name = f"USER_MAP_DC__{delegation_id}_FILE"
    p = os.getenv(env_name, "").strip()
    if not p:
        raise RuntimeError(f"{env_name} is not set")
    return Path(p)


def vault_get_user_map_dc(delegation_id: str) -> dict:
    from helpers import get_secret

    # remove; for local testing
    if LOCAL_DEV:
        path = local_user_map_file(delegation_id)
        print("\n\nPATH: ", path)
        if not path.exists():
            return {}
        return json.loads(path.read_text(encoding="utf-8") or "{}")

    # prefer inline user_map_dc from delegations_json
    delegations = json.loads(get_secret("DELEGATIONS_JSON", "[]") or "[]")
    for d in delegations:
        if str(d.get("id", "")).strip() == delegation_id:
            inline_map = d.get("user_map_dc")
            if isinstance(inline_map, dict) and inline_map:
                return inline_map

    # fallback to legacy separate KV path
    r = requests.get(
        f"{VAULT_ADDR}/v1/{user_map_path_for(delegation_id)}",
        headers={"X-Vault-Token": VAULT_BOT_TOKEN},
        timeout=20,
    )
    if r.status_code == 404:
        return {}
    r.raise_for_status()
    raw = r.json()["data"]["data"].get("value", "{}")
    return json.loads(raw)


def vault_put_user_map_dc(delegation_id: str, user_map: dict) -> None:
    from helpers import get_secret

    # remove; for local testing
    if LOCAL_DEV:
        path = local_user_map_file(delegation_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(user_map, indent=2), encoding="utf-8")
        return

    # 1) update user_map_dc in delegations_json
    delegations_raw = get_secret("DELEGATIONS_JSON", "[]") or "[]"
    delegations = json.loads(delegations_raw)

    found = False
    for d in delegations:
        if str(d.get("id", "")).strip() == delegation_id:
            d["user_map_dc"] = user_map
            found = True
            break

    if not found:
        # TODO: create a new delegation entry
        raise ValueError(f"delegation_id {delegation_id!r} not found in DELEGATIONS_JSON")

    # write updated delegations_json back to Vault
    kv_mount = os.getenv("VAULT_KV_MOUNT", "kv").strip()
    kv_path = os.getenv("VAULT_KV_PATH", "kv/data/nc-dc-task-delegator").strip()
    # kv_path is like "kv/data/nc-dc-task-delegator"
    delegations_kv_path = f"{kv_path}/delegations_json"
    
    if not delegations_kv_path:
        raise RuntimeError("VAULT_DELEGATIONS_JSON_PATH env var not set")

    r = requests.post(
        f"{VAULT_ADDR}/v1/{delegations_kv_path}",
        headers={"X-Vault-Token": VAULT_BOT_TOKEN},
        json={"data": {"value": json.dumps(delegations)}},
        timeout=20,
    )
    r.raise_for_status()

    # 2) also write to the old separate KV path (legacy)
    r = requests.post(
        f"{VAULT_ADDR}/v1/{user_map_path_for(delegation_id)}",
        headers={"X-Vault-Token": VAULT_BOT_TOKEN},
        json={"data": {"value": json.dumps(user_map)}},
        timeout=20,
    )
    r.raise_for_status()


# multi-delegation helpers; one DC user map per delegator
DELEGATIONS = json.loads(get_secret("DELEGATIONS_JSON", "[]"))


def get_delegations_for_user(discord_user_id: int) -> list[dict]:
    return [
        d
        for d in DELEGATIONS
        if str(d.get("delegator_discord_id", "")).strip() == str(discord_user_id)
    ]


def user_map_path_for(delegation_id: str) -> str:
    return f"{USER_MAP_PATH}/{delegation_id}"
