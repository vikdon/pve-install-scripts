#!/usr/bin/env bash
source <(curl -fsSL https://github.com/vikdon/pve-install-scripts/refs/heads/main/misc/build.func)
# OpenCart LXC installer for Proxmox VE (community-scripts style)
# Author: VikDon
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/opencart/opencart

APP="OpenCart"
var_tags="${var_tags:-ecommerce;shop;cms}"
var_disk="${var_disk:-8}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

# OpenCart version (override: var_oc_version=4.1.0.3)
var_oc_version="${var_oc_version:-4.1.0.3}"

header_info "$APP"
variables
color
catch_errors

update_script() {
  header_info
  check_container_storage
  check_container_resources

  if pct exec "$CTID" -- bash -lc '[[ -d /var/www/html/opencart ]]'; then
    msg_error "OpenCart is recommended to be updated via official procedure (backup + files + DB), not via this script."
    exit 1
  else
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN} ${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}/${CL}"
echo -e "${INFO}${YW} OpenCart installer:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}/install/${CL}"

# Show DB creds if present
DB_CREDS="$(pct exec "$CTID" -- bash -lc 'cat /root/.opencart_db_credentials 2>/dev/null || true')"
if [[ -n "${DB_CREDS}" ]]; then
  echo -e "${INFO}${YW} MariaDB credentials (stored in /root/.opencart_db_credentials):${CL}"
  echo -e "${TAB}${DB_CREDS}"
fi
