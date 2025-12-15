#!/usr/bin/env bash
# OpenCart install script (runs inside the LXC)
# Source: https://github.com/opencart/opencart
# License: MIT


# If FUNCTIONS_FILE_PATH not provided by build.func, fetch install.func
if [[ -z "${FUNCTIONS_FILE_PATH:-}" ]]; then
  FUNCTIONS_FILE_PATH="$(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/install.func)"
fi

# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# -------------------------
# User-configurable vars
# -------------------------
OC_VERSION="${OC_VERSION:-4.1.0.3}"

# PHP
PHP_VERSION="${PHP_VERSION:-8.2}"
PHP_FPM="${PHP_FPM:-YES}"
PHP_APACHE="${PHP_APACHE:-YES}"
PHP_MODULE="${PHP_MODULE:-mysql}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-512M}"
PHP_UPLOAD_MAX_FILESIZE="${PHP_UPLOAD_MAX_FILESIZE:-256M}"
PHP_POST_MAX_SIZE="${PHP_POST_MAX_SIZE:-256M}"
PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME:-300}"

# MariaDB
MARIADB_DB_NAME="${MARIADB_DB_NAME:-opencart_db}"
MARIADB_DB_USER="${MARIADB_DB_USER:-opencart}"

msg_info "Installing prerequisites"
$STD apt-get install -y curl ca-certificates unzip
msg_ok "Prerequisites installed"

msg_info "Installing PHP/Apache stack"
PHP_VERSION="${PHP_VERSION}" \
PHP_FPM="${PHP_FPM}" \
PHP_APACHE="${PHP_APACHE}" \
PHP_MODULE="${PHP_MODULE}" \
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT}" \
PHP_UPLOAD_MAX_FILESIZE="${PHP_UPLOAD_MAX_FILESIZE}" \
PHP_POST_MAX_SIZE="${PHP_POST_MAX_SIZE}" \
PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME}" \
setup_php
msg_ok "PHP/Apache stack installed"

# Ensure common OpenCart PHP extensions (safe to run even if some are already present)
msg_info "Installing OpenCart PHP extensions"
$STD apt-get install -y \
  "php${PHP_VERSION}-curl" \
  "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-intl" \
  "php${PHP_VERSION}-mbstring" \
  "php${PHP_VERSION}-xml" \
  "php${PHP_VERSION}-zip"
msg_ok "PHP extensions installed"

msg_info "Installing MariaDB"
setup_mariadb
MARIADB_DB_NAME="${MARIADB_DB_NAME}" MARIADB_DB_USER="${MARIADB_DB_USER}" setup_mariadb_db
msg_ok "MariaDB installed and database prepared"

# Save DB creds for web installer
cat >/root/.opencart_db_credentials <<EOF
Host: localhost
Database: ${MARIADB_DB_NAME}
User: ${MARIADB_DB_USER}
Password: ${MARIADB_DB_PASS}
EOF
chmod 600 /root/.opencart_db_credentials

msg_info "Downloading OpenCart v${OC_VERSION}"
cd /var/www/html
rm -rf /var/www/html/opencart /var/www/html/opencart-src || true
mkdir -p /var/www/html/opencart-src

curl -fsSL -o opencart.zip "https://github.com/opencart/opencart/archive/refs/tags/${OC_VERSION}.zip"
$STD unzip -q opencart.zip -d /var/www/html/opencart-src
rm -f opencart.zip
msg_ok "OpenCart downloaded"

msg_info "Deploying OpenCart to /var/www/html/opencart"
SRC_DIR="/var/www/html/opencart-src/opencart-${OC_VERSION}/upload"
if [[ ! -d "${SRC_DIR}" ]]; then
  msg_error "Unexpected archive layout. Missing: ${SRC_DIR}"
  exit 1
fi

mkdir -p /var/www/html/opencart
cp -a "${SRC_DIR}/." /var/www/html/opencart/

# Prepare configs for web installer
if [[ -f /var/www/html/opencart/config-dist.php && ! -f /var/www/html/opencart/config.php ]]; then
  cp /var/www/html/opencart/config-dist.php /var/www/html/opencart/config.php
fi
if [[ -f /var/www/html/opencart/admin/config-dist.php && ! -f /var/www/html/opencart/admin/config.php ]]; then
  cp /var/www/html/opencart/admin/config-dist.php /var/www/html/opencart/admin/config.php
fi

# SEO URLs: .htaccess
if [[ -f /var/www/html/opencart/.htaccess.txt && ! -f /var/www/html/opencart/.htaccess ]]; then
  cp /var/www/html/opencart/.htaccess.txt /var/www/html/opencart/.htaccess
fi

msg_info "Configuring storage directory"
mkdir -p /var/www/opencart-storage
if [[ -d /var/www/html/opencart/system/storage && ! -L /var/www/html/opencart/system/storage ]]; then
  cp -a /var/www/html/opencart/system/storage/. /var/www/opencart-storage/ || true
  rm -rf /var/www/html/opencart/system/storage
  ln -s /var/www/opencart-storage /var/www/html/opencart/system/storage
fi
msg_ok "Storage directory configured"

# Permissions
msg_info "Setting permissions"
chown -R www-data:www-data /var/www/html/opencart /var/www/opencart-storage
cd /var/www/html/opencart
find . -type d -exec chmod 755 {} \;
find . -type f -exec chmod 644 {} \;

# Writable paths for installer/runtime
chmod -R 775 /var/www/opencart-storage || true
chmod 664 /var/www/html/opencart/config.php /var/www/html/opencart/admin/config.php || true
msg_ok "Permissions set"

msg_info "Configuring Apache vhost"
cat <<'EOF' >/etc/apache2/sites-available/opencart.conf
<VirtualHost *:80>
  ServerName yourdomain.com
  DocumentRoot /var/www/html/opencart

  <Directory /var/www/html/opencart>
    AllowOverride All
    Require all granted
  </Directory>

  ErrorLog ${APACHE_LOG_DIR}/error.log
  CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

$STD a2enmod rewrite headers
$STD a2ensite opencart.conf
$STD a2dissite 000-default.conf
systemctl reload apache2
msg_ok "Apache configured"

motd_ssh
customize
cleanup_lxc

msg_ok "OpenCart base install completed"
echo -e "${INFO}${YW} Next step:${CL} open ${BGN}http://$(hostname -I | awk '{print $1}')/install/${CL} and complete the web installer."
echo -e "${INFO}${YW} DB credentials:${CL} saved in ${BGN}/root/.opencart_db_credentials${CL}"
echo -e "${INFO}${YW} After installation:${CL} remove ${BGN}/var/www/html/opencart/install${CL} and tighten permissions on config.php files."
