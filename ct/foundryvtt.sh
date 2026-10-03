#!/usr/bin/env bash
# Scripts base for this repo: without it the engine looks for install/ and the in-container
# `update` command in community-scripts/ProxmoxVE. Drop this line if contributed upstream.
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/thekannen/foundry-ops/main}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2026 Aaron Kannengieser
# Author: thekannen
# License: MIT | https://github.com/thekannen/foundry-ops/raw/main/LICENSE
# Source: https://foundryvtt.com/

# Foundry VTT is licensed software and is never part of this repo. Install and update
# both download the user's own copy from a Timed URL they paste in.

APP="FoundryVTT"
var_tags="${var_tags:-vtt;gaming}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

APP_DIR=/opt/foundryvtt
DATA_DIR=/var/lib/foundryvtt
FVTT_USER=foundry
STAGING_DIR="$APP_DIR/.staging"
ZIP_FILE="$APP_DIR/.foundryvtt.zip"
BACKUP_DIR=/var/backups/foundryvtt

# ---------------------------------------------------------------------------
# Shared with install/foundryvtt-install.sh. Each script is fetched on its own,
# so the functions are duplicated: keep both copies in sync.
# ---------------------------------------------------------------------------

# Ask for a Timed URL (or a zip already in the container) and fetch it to $1.
# The prompt comes right before the download: Timed URLs expire after 5 minutes.
fetch_foundry() {
  local dest="$1" src
  echo -e "${TAB3}Foundry VTT is licensed software, so this downloads your own copy."
  echo -e "${TAB3}foundryvtt.com -> Purchased Licenses -> choose the ${BGN}Node.js${CL} package -> ${BGN}Timed URL${CL}."
  echo -e "${TAB3}The link is valid for 5 minutes. A path to a zip inside this container also works."
  while true; do
    read -r -p "${TAB3}Timed URL or zip path: " src
    if [[ "$src" =~ ^https://[^[:space:]\"]+$ ]]; then
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
      return 0
    else
      msg_error "Not an https:// URL or an existing file."
    fi
  done
}

# Unzip $1 into $2 and find the app inside. Sets FVTT_ROOT (directory to install),
# FVTT_GEN (major version) and FVTT_BUILD.
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
  msg_ok "Found Foundry VTT ${FVTT_GEN}.${FVTT_BUILD}"
}

# Node major for a Foundry generation (wiki compatibility table: v14 needs 24,
# earlier versions do not run on 24).
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

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d "$APP_DIR/app" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  echo -e "${TAB3}Installed: Foundry VTT $(cat "$APP_DIR/version" 2>/dev/null || echo unknown)"
  msg_warn "A newer Foundry migrates worlds, systems and modules when it opens them. Back up the container (vzdump/PBS) first."

  local backup_data=yes prompt
  read -r -p "${TAB3}Also archive user data ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)) to ${BACKUP_DIR}? <Y/n> " prompt
  if [[ "${prompt,,}" =~ ^(n|no)$ ]]; then
    backup_data=no
  fi

  ensure_dependencies unzip jq
  fetch_foundry "$ZIP_FILE"
  stage_foundry "$ZIP_FILE" "$STAGING_DIR" || exit 1

  NODE_VERSION="$(node_for_generation "$FVTT_GEN")" setup_nodejs

  msg_info "Stopping Service"
  systemctl stop foundryvtt
  msg_ok "Stopped Service"

  if [[ "$backup_data" == yes ]]; then
    msg_info "Archiving user data"
    mkdir -p "$BACKUP_DIR"
    local archive
    archive="$BACKUP_DIR/foundryvtt-data-$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
    tar -czf "$archive" -C "$DATA_DIR" Data Config
    msg_ok "Archived user data to ${archive}"
  fi

  msg_info "Installing Foundry VTT ${FVTT_GEN}.${FVTT_BUILD}"
  # One rollback slot: the previous app/ (not user data) is kept as app.prev.
  rm -rf "$APP_DIR/app.prev"
  mv "$APP_DIR/app" "$APP_DIR/app.prev"
  mv "$FVTT_ROOT" "$APP_DIR/app"
  rm -rf "$STAGING_DIR"
  chown -R "$FVTT_USER:$FVTT_USER" "$APP_DIR/app"
  echo "${FVTT_GEN}.${FVTT_BUILD}" >"$APP_DIR/version"
  msg_ok "Installed Foundry VTT ${FVTT_GEN}.${FVTT_BUILD}"

  msg_info "Starting Service"
  systemctl start foundryvtt
  wait_for_foundry
  msg_ok "Started Service"
  msg_ok "Updated successfully! Previous version kept at ${APP_DIR}/app.prev"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL, then enter your license key:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:30000${CL}"
