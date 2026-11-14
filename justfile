# TunaOS local task surface for Bootsahi.
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

check: lint selftest backend-contract agent

lint:
    shellcheck -S warning scripts/*.sh components/*/*.sh

selftest:
    sudo ./scripts/selftest.sh

backend-contract:
    ./scripts/test-backend-contract.sh

asahi-bootbin-sync:
    ./components/asahi-bootbin-sync/test-asahi-bootbin-sync.sh

agent:
    ./components/bootsahi-agent/test-agent.sh

payload zip data:
    sudo ./scripts/test-payload.sh {{zip}} {{data}}
