# Design notes

## The rule: never package Foundry

Foundry VTT is paid software. This repo must never contain, cache, mirror or redistribute
any part of it, and the scripts must never write a Timed URL to disk or to logs.

- The user supplies the download: a Timed URL from their own license page (or a zip they
  already have). It is passed to curl on stdin, not argv.
- The zip and the staging directory are deleted as soon as the app is in place.
- `.gitignore` and the `guard` workflow reject archives and Foundry app files in commits.

## Built on the community-scripts engine

`ct/` and `install/` follow the [community-scripts](https://github.com/community-scripts/ProxmoxVE)
layout and source their engine (`community-scripts/core`), which supports third-party script
repos: it finds `install/` next to a local `ct/` (`COMMUNITY_SCRIPTS_ROOT`), or fetches it
from `COMMUNITY_SCRIPTS_URL`. `ct/foundryvtt.sh` sets that URL to this repo, which is also
what the in-container `update` command fetches. That one line is the only change needed if
the script is ever contributed upstream (plus their JSON metadata).

Using the engine gets container creation, storage/network prompts, the `update` entrypoint
and `setup_nodejs` for free, at the cost of running the engine's current code as root (the
same trade every community-scripts user makes).

## Timed URL lifetime

The URL is valid for 5 minutes. Everything slow (container creation, OS update, base
packages) runs before the prompt; the download starts right after it. Node.js is installed
after the download because the right Node major depends on the Foundry version in the zip.

## Differences from the wiki guide

| Wiki | Here | Why |
|---|---|---|
| pm2 under a sudo user | systemd unit, `foundry` system user without sudo | Container-native; nothing needs sudo at run time |
| nvm | NodeSource via `setup_nodejs`, version chosen from the zip | Survives updates; v14 needs 24, earlier versions break on 24 |
| `~/foundry`, `~/foundryuserdata` | `/opt/foundryvtt/app`, `/var/lib/foundryvtt` | Community-scripts convention; data path is easy to mount separately |
| Caddy in the same host | Left to the user's proxy (roadmap: optional Caddy) | Homelabs usually already run NPM/Caddy/Traefik |
| Fixed `main.js` path | Resolved at start by `run.sh` | It moved between v12, v13 and v14.365 |
| UPnP default (on) | Off | A container should not open router ports |

## Open questions

- Confirm `package.json` → `release.generation` / `release.build` on v12, v13 and v14 Node
  packages (falls back to `version`).
- Does Foundry's in-app updater keep working under `run.sh` across a `main.js` move? `run.sh`
  is written so it should.
- Name: "Foundry" is part of Foundry Gaming's marks. Check their guidelines on community
  project names before going public.
