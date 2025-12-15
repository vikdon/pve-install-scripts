#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/vikdon/pve-install-scripts/refs/heads/main/misc/build.func)
# Magento LXC installer for Proxmox VE (community-scripts style)
# Author: VikDon
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/magento/magento2

APP="Magento"
var_tags="${var_tags:-ecommerce;shop;cms}"
var_disk="${var_disk:-16}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

# Magento version (override: var_magento_version=2.4.7-p3)
var_magento_version="${var_magento_version:-2.4.7-p3}"

header_info "$APP"
variables
color
catch_errors

update_script() {
  header_info
  check_container_storage
  check_container_resources

  if pct exec "$CTID" -- bash -lc '[[ -d /var/www/html/magento ]]'; then
    msg_error "Magento should be updated via the official upgrade procedure, not through this script."
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
ADMIN_CREDS="$(pct exec "$CTID" -- bash -lc 'cat /root/.magento_admin_credentials 2>/dev/null || true')"
if [[ -n "${ADMIN_CREDS}" ]]; then
  echo -e "${INFO}${YW} Magento admin credentials:${CL}"
  echo -e "${TAB}${ADMIN_CREDS}"
fi

# Show DB creds if present
DB_CREDS="$(pct exec "$CTID" -- bash -lc 'cat /root/.magento_db_credentials 2>/dev/null || true')"
if [[ -n "${DB_CREDS}" ]]; then
  echo -e "${INFO}${YW} MariaDB credentials (stored in /root/.magento_db_credentials):${CL}"
  echo -e "${TAB}${DB_CREDS}"
fi
