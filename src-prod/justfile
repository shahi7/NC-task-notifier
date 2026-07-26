set dotenv-load
set dotenv-filename := ".env"

host_id := env_var_or_default("HOST_ID", "")
service_id := env_var_or_default("SERVICE_ID", "")
stack_name := env_var_or_default("STACK_NAME", "")

# informational only; compose derives the project from its top-level name key
project := host_id + "-" + service_id

default:
    @just --list

permissions-check:
    ./scripts/permissions.sh check

permissions-apply:
    ./scripts/permissions.sh apply

name:
    @echo "{{project}}"

check-env:
    @test -n "{{service_id}}" || { echo "SERVICE_ID is required in .env"; exit 1; }
    @test -n "{{host_id}}" || { echo "HOST_ID is required in .env"; exit 1; }
    @test -n "{{stack_name}}" || { echo "STACK_NAME is required in .env"; exit 1; }

check: check-env
    @docker compose config --services | awk ' \
      $$0 ~ /^(pg|rd|ts|va|srv|wrk)$/ { print "Cryptic service key not allowed: " $$0; bad=1 } \
      length($$0) < 3 { print "Service key too short: " $$0; bad=1 } \
      END { exit bad }'
    @docker compose config

config: check
    @docker compose config

up: check
    docker compose up -d

down:
    docker compose down --remove-orphans

restart: check
    docker compose up -d --force-recreate --remove-orphans

pull:
    docker compose pull

ps:
    docker compose ps

logs:
    docker compose logs -f

sh service:
    docker compose exec {{service}} sh

bash service:
    docker compose exec {{service}} bash
