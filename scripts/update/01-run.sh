#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2020 Umbrel. https://getumbrel.com
# SPDX-FileCopyrightText: 2021 Citadel and contributors
#
# SPDX-License-Identifier: MIT

set -euo pipefail

RELEASE=$1
CITADEL_ROOT=$2

# Only used on Umbrel OS and Citadel OS
SD_CARD_CITADEL_ROOT="/sd-root${CITADEL_ROOT}"

echo
echo "======================================="
echo "=============== UPDATE ================"
echo "======================================="
echo "=========== Stage: Install ============"
echo "======================================="
echo

[[ -f "/etc/default/umbrel" ]] && source "/etc/default/umbrel"
[[ -f "/etc/default/citadel" ]] && source "/etc/default/citadel"

IS_MIGRATING=0
# Check if UMBREL_OS is set
if [[ ! -z "${UMBREL_OS:-}" ]]; then
    echo "Umbrel OS is no longer supported."
  cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 50, "description": "We're sorry, but you tried installing the update on an unsupported OS. Please unplug your node and reflash the SD card with Citadel OS to continue.", "updateTo": "$RELEASE"}
EOF
    rm "${CITADEL_ROOT}/statuses/update-in-progress"
    docker stop bitcoin
    docker stop lnd
    docker stop electrs
    exit 1
fi

# If the Citadel OS version is 0.0.1, fail
if [[ ! -z "${CITADEL_OS:-}" ]] && [[ "${CITADEL_OS}" == "0.0.1" ]]; then
    echo "Citadel OS version is 0.0.1. This is not supported."
  cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 50, "description": "We're sorry, but you tried installing the update on an unsupported OS. Please unplug your node and reflash the SD card with Citadel OS to continue.", "updateTo": "$RELEASE"}
EOF
    rm "${CITADEL_ROOT}/statuses/update-in-progress"
    docker stop bitcoin
    docker stop lnd
    docker stop electrs
    echo "We're sorry, but you tried installing the update on an unsupported OS. Please unplug your node and reflash the SD card with Citadel OS to continue."
    exit 1
fi

# Make Citadel OS specific updates
if [[ ! -z "${CITADEL_OS:-}" ]]; then
    echo
    echo "============================================="
    echo "Installing on Citadel OS $CITADEL_OS"
    echo "============================================="
    echo
    
    # Update SD card installation
    if  [[ -f "${SD_CARD_CITADEL_ROOT}/.umbrel" ]] || [[ -f "${SD_CARD_CITADEL_ROOT}/.citadel" ]]; then
        echo "Replacing ${SD_CARD_CITADEL_ROOT} on SD card with the new release"
        rsync --archive \
            --verbose \
            --include-from="${CITADEL_ROOT}/.citadel-${RELEASE}/scripts/update/.updateinclude" \
            --exclude-from="${CITADEL_ROOT}/.citadel-${RELEASE}/scripts/update/.updateignore" \
            --delete \
            "${CITADEL_ROOT}/.citadel-${RELEASE}/" \
            "${SD_CARD_CITADEL_ROOT}/"

        echo "Fixing permissions"
        chown -R 1000:1000 "${SD_CARD_CITADEL_ROOT}/"
    else
        echo "ERROR: No Umbrel or Citadel installation found at SD root ${SD_CARD_CITADEL_ROOT}"
        echo "Skipping updating on SD Card..."
    fi

    # This makes sure systemd services are always updated (and new ones are enabled).
    CITADEL_SYSTEMD_SERVICES="${CITADEL_ROOT}/.citadel-${RELEASE}/scripts/citadel-os/services/*.service"
    for service_path in $CITADEL_SYSTEMD_SERVICES; do
      service_name=$(basename "${service_path}")
      install -m 644 "${service_path}" "/etc/systemd/system/${service_name}"
      systemctl enable "${service_name}"
    done
fi

cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 33, "description": "Configuring settings", "updateTo": "$RELEASE"}
EOF

# Checkout to the new release
cd "$CITADEL_ROOT"/.citadel-"$RELEASE"

# Configure new install
echo "Configuring new release"
cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 40, "description": "Configuring new release", "updateTo": "$RELEASE"}
EOF

./scripts/configure

# Pulling new containers
echo "Pulling new containers"
cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 50, "description": "Pulling new containers", "updateTo": "$RELEASE"}
EOF
docker compose pull

# Stopping karen
echo "Stopping background daemon"
cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 65, "description": "Stopping background daemon", "updateTo": "$RELEASE"}
EOF
pkill -f "\./karen" || true

# Overlay home dir structure with new dir tree
echo "Overlaying $CITADEL_ROOT/ with new directory tree"
rsync --archive \
    --verbose \
    --include-from="$CITADEL_ROOT/.citadel-$RELEASE/scripts/update/.updateinclude" \
    --exclude-from="$CITADEL_ROOT/.citadel-$RELEASE/scripts/update/.updateignore" \
    --delete \
    "$CITADEL_ROOT"/.citadel-"$RELEASE"/ \
    "$CITADEL_ROOT"/

# Fix permissions
echo "Fixing permissions"
find "$CITADEL_ROOT" -path "$CITADEL_ROOT/app-data" -prune -o -exec chown 1000:1000 {} +
chmod -R 700 "$CITADEL_ROOT"/tor/data/*

# If "$CITADEL_ROOT"/db/umbrel-seed exists, move it to "$CITADEL_ROOT"/db/citadel-seed
if [[ -f "$CITADEL_ROOT"/db/umbrel-seed ]]; then
    echo "Moving $CITADEL_ROOT/db/umbrel-seed to $CITADEL_ROOT/db/citadel-seed"
    mv "$CITADEL_ROOT"/db/umbrel-seed "$CITADEL_ROOT"/db/citadel-seed
fi

cd "$CITADEL_ROOT"
echo "Updating installed apps"
cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 70, "description": "Updating installed apps", "updateTo": "$RELEASE"}
EOF
"${CITADEL_ROOT}/app/app-manager.py" update-online
for app in $("$CITADEL_ROOT/app/app-manager.py" ls-installed); do
  if [[ "${app}" != "" ]]; then
    echo "${app}..."
    "${CITADEL_ROOT}/app/app-manager.py" compose "${app}" pull
  fi
done
wait

# If CITADEL_ROOT doesn't contain services/installed.json, then put '["electrs"]' into it.
# This is to ensure that the 0.5.0 update doesn't remove electrs.
if [[ ! -f "${CITADEL_ROOT}/services/installed.json" ]]; then
  echo '["electrs"]' > "${CITADEL_ROOT}/services/installed.json"
fi

# Start updated containers
echo "Starting new containers"
cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 80, "description": "Starting new containers", "updateTo": "$RELEASE"}
EOF
cd "$CITADEL_ROOT"
docker network rm citadel_main_network || true
./scripts/start

cat <<EOF > "$CITADEL_ROOT"/statuses/update-status.json
{"state": "success", "progress": 100, "description": "Successfully installed Citadel $RELEASE", "updateTo": ""}
EOF

# Make Citadel OS specific post-update changes
if [[ ! -z "${CITADEL_OS:-}" ]]; then
  # Delete unused Docker images on Citadel OS
  echo "Deleting previous images"
  docker image prune --all --force
fi
