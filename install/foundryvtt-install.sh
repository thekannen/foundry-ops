#!/usr/bin/env bash

# Copyright (c) 2026 Aaron Kannengieser
# Author: thekannen
# License: MIT | https://github.com/thekannen/foundry-ops/raw/main/LICENSE
# Source: https://foundryvtt.com/

# Foundry VTT is licensed software. This script never contains, caches or redistributes
# it: it downloads the copy tied to YOUR license, from the Timed URL you paste in.
# Steps follow the community wiki's Linux guide (foundryvtt.wiki/en/setup/linux-installation),
# with systemd in place of pm2 and Caddy left to your own reverse proxy.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

APP_DIR=/opt/foundryvtt
DATA_DIR=/var/lib/foundryvtt
FVTT_USER=foundry
STAGING_DIR="$APP_DIR/.staging"
ZIP_FILE="$APP_DIR/.foundryvtt.zip"

# ---------------------------------------------------------------------------
# Shared with ct/foundryvtt.sh (update_script). Each script is fetched on its own,
# so the functions are duplicated: keep both copies in sync.
# ---------------------------------------------------------------------------

# Fetch Foundry to $1 from FOUNDRY_SOURCE, or from a Timed URL / zip path typed at
# the prompt. The prompt comes right before the download: Timed URLs expire after 5
# minutes. Without a terminal (Ansible, CI), FOUNDRY_SOURCE is required.
fetch_foundry() {
  local dest="$1" src="${FOUNDRY_SOURCE:-}"
  if [[ -z "$src" && ! -t 0 ]]; then
    msg_error "No terminal to ask on: set FOUNDRY_SOURCE to a Timed URL or a zip path inside the container."
    return 1
  fi
  if [[ -z "$src" ]]; then
    echo -e "${TAB3}Foundry VTT is licensed software, so this downloads your own copy."
    echo -e "${TAB3}foundryvtt.com -> Purchased Licenses -> choose the ${BGN}Node.js${CL} package -> ${BGN}Timed URL${CL}."
    echo -e "${TAB3}The link is valid for 5 minutes. A path to a zip inside this container also works."
  fi
  while true; do
    if [[ -z "$src" ]]; then
      read -r -p "${TAB3}Timed URL or zip path: " src
    fi
    if [[ "$src" =~ ^https?://[^[:space:]\"]+$ ]]; then
      msg_info "Downloading Foundry VTT"
      # URL via stdin, not argv: it is a credential for its 5-minute life.
      if printf 'url = "%s"\n' "$src" | curl -fsSL --retry 3 --config - -o "$dest"; then
        msg_ok "Downloaded Foundry VTT"
        return 0
      fi
      rm -f "$dest"
      msg_error "Download failed. Timed URLs expire after 5 minutes: copy a fresh one."
    elif [[ -f "$src" ]]; then
      cp "$src" "$dest"
      msg_ok "Using Foundry VTT zip ${src}"
      return 0
    else
      msg_error "Not an http(s):// URL or an existing file."
    fi
    # A bad FOUNDRY_SOURCE cannot be corrected without a terminal.
    if [[ -n "${FOUNDRY_SOURCE:-}" || ! -t 0 ]]; then
      return 1
    fi
    src=""
  done
}

# Unzip $1 into $2 and find the app inside. Sets FVTT_ROOT (directory to install),
# FVTT_GEN (major version), FVTT_BUILD and FVTT_NODE (Node.js major to run it on).
stage_foundry() {
  local zip="$1" staging="$2" rel pkg entries
  rm -rf "$staging"
  mkdir -p "$staging"
  if ! unzip -q "$zip" -d "$staging"; then
    msg_error "Not a valid zip. Download the Node.js (or Linux) package, not Windows/macOS."
    return 1
  fi
  rm -f "$zip"

  # main.js moved between versions (v13 Node package: root; v14.365+: resources/app).
  # Descend through single wrapper folders until one of those layouts is found, so
  # the package's own structure (e.g. resources/app) is kept intact.
  FVTT_ROOT="$staging"
  pkg=""
  while true; do
    for rel in main.js resources/app/main.js app/main.js; do
      if [[ -f "$FVTT_ROOT/$rel" ]]; then
        pkg="$(dirname "$FVTT_ROOT/$rel")/package.json"
        break 2
      fi
    done
    mapfile -t entries < <(find "$FVTT_ROOT" -mindepth 1 -maxdepth 1)
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
      FVTT_ROOT="${entries[0]}"
    else
      break
    fi
  done
  if [[ -z "$pkg" || ! -f "$pkg" ]]; then
    rm -rf "$staging"
    msg_error "No Foundry main.js/package.json in that zip. Choose the Node.js package."
    return 1
  fi
  FVTT_GEN="$(jq -r '.release.generation // (.version | split(".")[0]) // empty' "$pkg")"
  FVTT_BUILD="$(jq -r '.release.build // (.version | split(".")[1]) // empty' "$pkg")"
  # v14 packages name their Node major (release.node_version); older ones use the table.
  FVTT_NODE="$(jq -r '.release.node_version // empty' "$pkg")"
  if [[ ! "$FVTT_NODE" =~ ^[0-9]+$ ]]; then
    FVTT_NODE="$(node_for_generation "$FVTT_GEN")"
  fi
  msg_ok "Found Foundry VTT ${FVTT_GEN}.${FVTT_BUILD}"
}

# Node major for a Foundry generation when package.json does not name one (wiki
# compatibility table: v14 needs 24, earlier versions do not run on 24).
node_for_generation() {
  case "${1:-}" in
  '' | *[!0-9]*) echo 24 ;;
  *)
    if [[ "$1" -ge 14 ]]; then
      echo 24
    elif [[ "$1" -eq 13 ]]; then
      echo 22
    else
      echo 20
    fi
    ;;
  esac
}

# Wait for Foundry to answer on :30000 (license page or setup screen).
wait_for_foundry() {
  local _
  for _ in {1..60}; do
    if curl -fsS -o /dev/null http://127.0.0.1:30000; then
      return 0
    fi
    sleep 1
  done
  msg_error "Foundry did not answer on port 30000. Check: journalctl -u foundryvtt"
  return 1
}

# ---------------------------------------------------------------------------

msg_info "Installing Dependencies"
$STD apt install -y unzip jq
msg_ok "Installed Dependencies"

# FOUNDRY_PROXY (yes/no) and FOUNDRY_HOSTNAME skip these questions; without a
# terminal they default to no proxy.
BEHIND_PROXY="${FOUNDRY_PROXY:-}"
FVTT_HOSTNAME="${FOUNDRY_HOSTNAME:-}"
if [[ -z "$BEHIND_PROXY" && -t 0 ]]; then
  read -r -p "${TAB3}Will players reach Foundry through an HTTPS reverse proxy (NPM, Caddy, Traefik)? <y/N> " BEHIND_PROXY
  if [[ "${BEHIND_PROXY,,}" =~ ^(y|yes)$ && -z "$FVTT_HOSTNAME" ]]; then
    read -r -p "${TAB3}Public hostname for invite links (e.g. vtt.example.com, blank to skip): " FVTT_HOSTNAME
  fi
fi
if [[ "${BEHIND_PROXY,,}" =~ ^(y|yes)$ ]]; then
  BEHIND_PROXY=yes
else
  BEHIND_PROXY=no
fi

mkdir -p "$APP_DIR"
fetch_foundry "$ZIP_FILE" || exit 1
stage_foundry "$ZIP_FILE" "$STAGING_DIR" || exit 1

NODE_VERSION="$FVTT_NODE" setup_nodejs

msg_info "Installing Foundry VTT ${FVTT_GEN}.${FVTT_BUILD}"
useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$FVTT_USER"
mv "$FVTT_ROOT" "$APP_DIR/app"
rm -rf "$STAGING_DIR"
mkdir -p "$DATA_DIR"
echo "${FVTT_GEN}.${FVTT_BUILD}" >"$APP_DIR/version"

# Launcher outside app/ so upgrades (ours or Foundry's in-app updater) can move main.js.
cat <<'EOF' >"$APP_DIR/run.sh"
#!/usr/bin/env bash
# Started by foundryvtt.service. Finds main.js at run time: its path differs between
# Foundry versions, and the in-app updater can change it.
APP=/opt/foundryvtt/app
for rel in main.js resources/app/main.js app/main.js; do
  if [[ -f "$APP/$rel" ]]; then
    exec /usr/bin/node "$APP/$rel" --dataPath=/var/lib/foundryvtt "$@"
  fi
done
echo "Foundry main.js not found under $APP" >&2
exit 1
EOF
chmod 755 "$APP_DIR/run.sh"
# The service user owns app/ too, so Foundry's in-app updater works.
chown -R "$FVTT_USER:$FVTT_USER" "$APP_DIR/app" "$DATA_DIR"
msg_ok "Installed Foundry VTT ${FVTT_GEN}.${FVTT_BUILD}"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/foundryvtt.service
[Unit]
Description=Foundry Virtual Tabletop
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${FVTT_USER}
Group=${FVTT_USER}
ExecStart=${APP_DIR}/run.sh
Restart=on-failure
RestartSec=5
# Sandboxing beyond this (ProtectSystem, PrivateTmp) can fail in unprivileged LXCs.
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now foundryvtt
msg_ok "Created Service"

# Foundry writes Config/options.json on first start; adjust it once it exists.
msg_info "Configuring Foundry"
OPTIONS="$DATA_DIR/Config/options.json"
for _ in {1..60}; do
  if [[ -s "$OPTIONS" ]]; then break; fi
  sleep 1
done
if [[ -s "$OPTIONS" ]]; then
  systemctl stop foundryvtt
  # No UPnP: a homelab container should never open router ports on its own.
  JQ_FILTER='.upnp = false'
  if [[ "$BEHIND_PROXY" == yes ]]; then
    JQ_FILTER+=' | .proxySSL = true | .proxyPort = 443'
    if [[ -n "$FVTT_HOSTNAME" ]]; then
      # shellcheck disable=SC2016 # $host is a jq variable
      JQ_FILTER+=' | .hostname = $host'
    fi
  fi
  jq --arg host "$FVTT_HOSTNAME" "$JQ_FILTER" "$OPTIONS" >"$OPTIONS.tmp"
  mv "$OPTIONS.tmp" "$OPTIONS"
  chown "$FVTT_USER:$FVTT_USER" "$OPTIONS"
  systemctl start foundryvtt
  msg_ok "Configured Foundry"
else
  msg_warn "options.json not created yet; set upnp/proxy options in Foundry's setup screen"
fi
wait_for_foundry

motd_ssh
customize
cleanup_lxc
