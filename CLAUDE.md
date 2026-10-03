# foundry-ops

Proxmox tooling for self-hosting Foundry VTT. Private for now; will go public.

## Hard rule

Never add Foundry VTT itself to this repo, in any form: no zips, no extracted app files, no
mirrors or cached download links, no Timed URLs (in code, docs, tests or logs). Scripts take
the user's own Timed URL at run time and delete the download after installing.

## Conventions

- `ct/foundryvtt.sh` (runs on the PVE host; `update_script` runs inside the CT) and
  `install/foundryvtt-install.sh` (runs inside the new CT) follow community-scripts style and
  source `community-scripts/core`. Each is fetched on its own, so the shared functions
  (`fetch_foundry`, `stage_foundry`, `node_for_generation`, `wait_for_foundry`) are duplicated
  between them: change both together.
- Layout in the container: app `/opt/foundryvtt/app`, data `/var/lib/foundryvtt`, service
  `foundryvtt`, user `foundry`.
- Test on a throwaway CT on a Proxmox node before merging; record which Foundry versions
  were tested in the PR.
- Related: `~/Repos/proxmox-iac` (the owner's homelab IaC) and
  `~/Repos/Home-Scripts/scripts/bash/foundry` (the pm2-based scripts this replaces).
