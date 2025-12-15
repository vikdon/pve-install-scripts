#!/usr/bin/env bash
# Magento install script (runs inside the LXC)
# Source: https://github.com/magento/magento2
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
MAGENTO_VERSION="${MAGENTO_VERSION:-2.4.7-p3}"
MAGENTO_DIR="${MAGENTO_DIR:-/var/www/html/magento}"
MAGENTO_BASE_URL="${MAGENTO_BASE_URL:-http://$(hostname -I | awk '{print $1}')/}"
MAGENTO_REPO_PUBLIC_KEY="${MAGENTO_REPO_PUBLIC_KEY:-}"
MAGENTO_REPO_PRIVATE_KEY="${MAGENTO_REPO_PRIVATE_KEY:-}"

# PHP
PHP_VERSION="${PHP_VERSION:-8.2}"
PHP_FPM="${PHP_FPM:-YES}"
PHP_APACHE="${PHP_APACHE:-YES}"
PHP_MODULE="${PHP_MODULE:-mysql}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-2048M}"
PHP_UPLOAD_MAX_FILESIZE="${PHP_UPLOAD_MAX_FILESIZE:-64M}"
PHP_POST_MAX_SIZE="${PHP_POST_MAX_SIZE:-64M}"
PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME:-300}"

# MariaDB
MARIADB_DB_NAME="${MARIADB_DB_NAME:-magento_db}"
MARIADB_DB_USER="${MARIADB_DB_USER:-magento}"

msg_info "Installing prerequisites"
$STD apt-get install -y curl ca-certificates unzip git
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

msg_info "Installing Magento PHP extensions"
$STD apt-get install -y \
  "php${PHP_VERSION}-bcmath" \
  "php${PHP_VERSION}-curl" \
  "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-intl" \
  "php${PHP_VERSION}-mbstring" \
  "php${PHP_VERSION}-soap" \
  "php${PHP_VERSION}-xml" \
  "php${PHP_VERSION}-xsl" \
  "php${PHP_VERSION}-zip" \
  "php${PHP_VERSION}-sodium"
msg_ok "PHP extensions installed"

msg_info "Installing MariaDB"
setup_mariadb
MARIADB_DB_NAME="${MARIADB_DB_NAME}" MARIADB_DB_USER="${MARIADB_DB_USER}" setup_mariadb_db
msg_ok "MariaDB installed and database prepared"

# Save DB creds for later CLI installer use
cat >/root/.magento_db_credentials <<EOF
Host: localhost
Database: ${MARIADB_DB_NAME}
User: ${MARIADB_DB_USER}
Password: ${MARIADB_DB_PASS}
EOF
chmod 600 /root/.magento_db_credentials

msg_info "Installing Composer"
if ! command -v composer >/dev/null 2>&1; then
  php -r "copy('https://getcomposer.org/installer','composer-setup.php');"
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null
  php -r "unlink('composer-setup.php');"
  msg_ok "Composer installed"
else
  msg_ok "Composer already installed"
fi

mkdir -p /var/www/html
rm -rf "${MAGENTO_DIR}"

NEEDS_COMPOSER_AUTH="no"
if [[ -n "${MAGENTO_REPO_PUBLIC_KEY}" && -n "${MAGENTO_REPO_PRIVATE_KEY}" ]]; then
  msg_info "Downloading Magento v${MAGENTO_VERSION} via Composer"
  export COMPOSER_ALLOW_SUPERUSER=1
  export COMPOSER_MEMORY_LIMIT=-1
  export COMPOSER_HOME="${COMPOSER_HOME:-/root/.config/composer}"
  mkdir -p "${COMPOSER_HOME}"
  cat >"${COMPOSER_HOME}/auth.json" <<EOF
{
  "http-basic": {
    "repo.magento.com": {
      "username": "${MAGENTO_REPO_PUBLIC_KEY}",
      "password": "${MAGENTO_REPO_PRIVATE_KEY}"
    }
  }
}
EOF
  chmod 600 "${COMPOSER_HOME}/auth.json"
  COMPOSER_ALLOW_SUPERUSER=1 composer create-project \
    --repository-url=https://repo.magento.com/ \
    magento/project-community-edition="${MAGENTO_VERSION}" \
    "${MAGENTO_DIR}"
  msg_ok "Magento downloaded"
else
  NEEDS_COMPOSER_AUTH="yes"
  SRC_DIR="/var/www/html/magento-src"
  rm -rf "${SRC_DIR}"
  mkdir -p "${SRC_DIR}"
  msg_info "Downloading Magento source v${MAGENTO_VERSION}"
  cd "${SRC_DIR}"
  curl -fsSL -o magento.zip "https://github.com/magento/magento2/archive/refs/tags/${MAGENTO_VERSION}.zip"
  $STD unzip -q magento.zip
  rm -f magento.zip
  MAGENTO_SRC_PATH="${SRC_DIR}/magento2-${MAGENTO_VERSION}"
  if [[ ! -d "${MAGENTO_SRC_PATH}" ]]; then
    msg_error "Unexpected archive layout. Missing: ${MAGENTO_SRC_PATH}"
    exit 1
  fi
  mkdir -p "${MAGENTO_DIR}"
  cp -a "${MAGENTO_SRC_PATH}/." "${MAGENTO_DIR}/"
  msg_ok "Magento source downloaded (Composer dependencies still required)"
fi

msg_info "Setting permissions"
chown -R www-data:www-data "${MAGENTO_DIR}"
find "${MAGENTO_DIR}" -type d -exec chmod 755 {} \;
find "${MAGENTO_DIR}" -type f -exec chmod 644 {} \;
for writable in var generated pub/media pub/static app/etc; do
  if [[ -d "${MAGENTO_DIR}/${writable}" ]]; then
    chmod -R g+ws "${MAGENTO_DIR}/${writable}" || true
    chown -R www-data:www-data "${MAGENTO_DIR}/${writable}"
  fi
done
msg_ok "Permissions set"

msg_info "Configuring Apache vhost"
cat <<EOF >/etc/apache2/sites-available/magento.conf
<VirtualHost *:80>
  ServerName yourdomain.com
  DocumentRoot ${MAGENTO_DIR}

  <Directory ${MAGENTO_DIR}>
    AllowOverride All
    Require all granted
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/magento-error.log
  CustomLog \${APACHE_LOG_DIR}/magento-access.log combined
</VirtualHost>
EOF
$STD a2enmod rewrite headers expires
$STD a2ensite magento.conf
$STD a2dissite 000-default.conf
systemctl reload apache2
msg_ok "Apache configured"

motd_ssh
customize
cleanup_lxc

if [[ "${NEEDS_COMPOSER_AUTH}" == "yes" ]]; then
  echo -e "${INFO}${YW} Composer auth required:${CL} add repo.magento.com keys then run ${BGN}composer install${CL} inside ${BGN}${MAGENTO_DIR}${CL}"
fi

msg_ok "Magento base install files deployed"
echo -e "${INFO}${YW} Next step:${CL} run ${BGN}bin/magento setup:install${CL} from ${BGN}${MAGENTO_DIR}${CL} with your desired base-url/admin credentials."
echo -e "${INFO}${YW} DB credentials:${CL} saved in ${BGN}/root/.magento_db_credentials${CL}"
echo -e "${INFO}${YW} Base URL suggestion:${CL} ${BGN}${MAGENTO_BASE_URL}${CL}"
