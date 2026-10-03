# foundry-ops

Self-hosting tooling for [Foundry Virtual Tabletop](https://foundryvtt.com/) on Proxmox VE.
Starts with a [community-scripts](https://community-scripts.org/)-style LXC installer; backup,
restore, staging clones and upgrade tooling follow (see [Roadmap](#roadmap)).

> [!IMPORTANT]
> **Foundry VTT is licensed software and is never part of this repo.** Nothing here contains,
> caches or redistributes it. The installer and the updater ask for the **Timed URL** from your
> own [Purchased Licenses](https://foundryvtt.com/me/licenses) page and download your copy
> directly into your container. You need a Foundry license to use this.

## Install (Proxmox VE host shell)

While the repo is private, copy it to a node and run the CT script from the checkout. The
community-scripts engine finds `install/` next to `ct/` on its own:

```bash
scp -r ~/Repos/foundry-ops root@<node>:/root/
ssh root@<node>
bash /root/foundry-ops/ct/foundryvtt.sh
```

Once public, the usual one-liner works:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/thekannen/foundry-ops/main/ct/foundryvtt.sh)"
```

The script creates the container (defaults: Debian 13, unprivileged, 2 cores, 4 GB RAM,
20 GB disk) and then, inside it:

1. Installs `unzip` and `jq`, and asks whether Foundry sits behind an HTTPS reverse proxy.
2. Asks for the **Timed URL** (foundryvtt.com → Purchased Licenses → **Node.js** package →
   Timed URL). It downloads immediately; the URL is valid for 5 minutes. A path to a zip
   already inside the container works too.
3. Reads the Foundry version from the zip and installs the matching Node.js (v14: 24,
   v13: 22, older: 20).
4. Installs to `/opt/foundryvtt/app`, user data to `/var/lib/foundryvtt`, and runs it as the
   `foundry` system user under `foundryvtt.service`.
5. Sets `options.json`: UPnP off; behind a proxy, `proxySSL`, `proxyPort: 443` and your
   hostname.

Open `http://<container-ip>:30000` and enter your license key.

## Update

Inside the container, run `update` (once public), or while private, from the node:

```bash
pct push <ctid> /root/foundry-ops/ct/foundryvtt.sh /root/foundryvtt.sh
lxc-attach -n <ctid> -- bash /root/foundryvtt.sh
```

It asks for a new Timed URL, optionally archives `Data/` and `Config/` to
`/var/backups/foundryvtt`, swaps the app, matches Node.js, and keeps the previous version in
`/opt/foundryvtt/app.prev`. Back up the container (vzdump/PBS) first: a newer Foundry
migrates worlds when it opens them, and that does not roll back.

Rollback of the app (not of migrated worlds):

```bash
systemctl stop foundryvtt
mv /opt/foundryvtt/app /opt/foundryvtt/app.bad && mv /opt/foundryvtt/app.prev /opt/foundryvtt/app
systemctl start foundryvtt
```

## Layout

| Path | What |
|---|---|
| `/opt/foundryvtt/app` | Foundry itself (owned by `foundry`, so the in-app updater works) |
| `/opt/foundryvtt/run.sh` | Launcher; finds `main.js` at run time (its path moved between versions) |
| `/opt/foundryvtt/version` | Version installed by these scripts |
| `/var/lib/foundryvtt` | `--dataPath`: `Data/`, `Config/`, `Logs/` |
| `foundryvtt.service` | systemd unit (replaces the wiki's pm2) |

## Moving from a wiki-style install

The [wiki guide](https://foundryvtt.wiki/en/setup/linux-installation) puts data in
`~/foundryuserdata` and runs pm2. Install fresh here, then copy only user data across:

```bash
systemctl stop foundryvtt
# copy the old Data/ and Config/ into /var/lib/foundryvtt/
chown -R foundry:foundry /var/lib/foundryvtt
systemctl start foundryvtt
```

Check `Config/options.json` afterwards: an old `dataPath` or `port` there overrides nothing,
but `proxySSL`/`hostname` come across as they were.

## Roadmap

- Backup / restore / clone-to-staging, ported from the Home-Scripts Foundry scripts and
  parameterised for this layout.
- Optional Caddy in the container for setups without a reverse proxy (wiki section C13+).
- Test matrix: v12, v13, v14 Node packages; fresh install and update.
- Public release, then decide on contributing upstream to community-scripts.

See [docs/design.md](docs/design.md) for the decisions behind this.

## License

MIT for the scripts in this repo. Foundry VTT itself is © Foundry Gaming LLC and is covered by
its own license; this project is not affiliated with or endorsed by Foundry Gaming.
