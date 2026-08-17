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
    # remove; for local testing
    if LOCAL_DEV:
        path = local_user_map_file(delegation_id)
        print("\n\nPATH: ", path)
        if not path.exists():
            return {}
        return json.loads(path.read_text(encoding="utf-8") or "{}")

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
    # remove; for local testing
    if LOCAL_DEV:
        path = local_user_map_file(delegation_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(user_map, indent=2), encoding="utf-8")
        return

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
