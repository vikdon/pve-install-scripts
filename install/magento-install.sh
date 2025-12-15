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
MAGENTO_BASE_URL_SECURE="${MAGENTO_BASE_URL_SECURE:-https://$(hostname -I | awk '{print $1}')/}"
MAGENTO_REPO_PUBLIC_KEY="${MAGENTO_REPO_PUBLIC_KEY:-}"
MAGENTO_REPO_PRIVATE_KEY="${MAGENTO_REPO_PRIVATE_KEY:-}"
MARIADB_TARGET_VERSION="${MARIADB_TARGET_VERSION:-10.6.24}"
MAGENTO_ADMIN_FIRSTNAME="${MAGENTO_ADMIN_FIRSTNAME:-Admin}"
MAGENTO_ADMIN_LASTNAME="${MAGENTO_ADMIN_LASTNAME:-User}"
MAGENTO_ADMIN_EMAIL="${MAGENTO_ADMIN_EMAIL:-admin@example.com}"
MAGENTO_ADMIN_USER="${MAGENTO_ADMIN_USER:-admin}"
MAGENTO_ADMIN_PASSWORD="${MAGENTO_ADMIN_PASSWORD:-}"
MAGENTO_BACKEND_FRONTNAME="${MAGENTO_BACKEND_FRONTNAME:-admin}"
MAGENTO_LANGUAGE="${MAGENTO_LANGUAGE:-en_US}"
MAGENTO_CURRENCY="${MAGENTO_CURRENCY:-USD}"
MAGENTO_TIMEZONE="${MAGENTO_TIMEZONE:-UTC}"
MAGENTO_USE_SECURE="${MAGENTO_USE_SECURE:-0}"
MAGENTO_USE_SECURE_ADMIN="${MAGENTO_USE_SECURE_ADMIN:-0}"
MAGENTO_SEARCH_ENGINE="${MAGENTO_SEARCH_ENGINE:-opensearch}"
MAGENTO_SEARCH_HOST="${MAGENTO_SEARCH_HOST:-localhost}"
MAGENTO_SEARCH_PORT="${MAGENTO_SEARCH_PORT:-9200}"
MAGENTO_SEARCH_INDEX_PREFIX="${MAGENTO_SEARCH_INDEX_PREFIX:-magento}"
MAGENTO_DISABLE_MODULES="${MAGENTO_DISABLE_MODULES:-Magento_TwoFactorAuth}"
MAGENTO_SALES_ORDER_PREFIX="${MAGENTO_SALES_ORDER_PREFIX:-ORD}"

generate_random_password() {
  local length="${1:-16}"
  local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local pass=""
  while ((${#pass} < length)); do
    local rand
    rand=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
    if [[ -z "${rand}" ]]; then
      continue
    fi
    rand=$((rand % ${#chars}))
    pass+="${chars:rand:1}"
  done
  echo "${pass}"
}

is_valid_password() {
  local pwd="$1"
  [[ ${#pwd} -ge 8 && "$pwd" =~ [A-Za-z] && "$pwd" =~ [0-9] ]]
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local input=""
  read -rp "$(printf "%s [%s]: " "$prompt" "$default")" input || true
  if [[ -z "${input}" ]]; then
    input="$default"
  fi
  printf -v "${var_name}" "%s" "${input}"
}

prompt_secret_with_default() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local input=""
  read -rsp "$(printf "%s [%s]: " "$prompt" "$default")" input || true
  echo
  if [[ -z "${input}" ]]; then
    input="$default"
  fi
  printf -v "${var_name}" "%s" "${input}"
}

prompt_password_with_policy() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local input=""
  while true; do
    read -rsp "$(printf "%s [%s]: " "$prompt" "$default")" input || true
    echo
    if [[ -z "${input}" ]]; then
      input="$default"
    fi
    if is_valid_password "${input}"; then
      printf -v "${var_name}" "%s" "${input}"
      break
    fi
    echo "Password must be at least 8 characters long and contain letters plus digits. Please try again." >&2
  done
}

normalize_url() {
  local url="$1"
  [[ -z "${url}" ]] && echo "" && return
  if [[ "${url}" != *"/" ]]; then
    url="${url}/"
  fi
  echo "${url}"
}

is_valid_https_domain_url() {
  local url="$1"
  [[ -z "${url}" ]] && return 1
  [[ "${url}" =~ ^https:// ]] || return 1
  local rest="${url#https://}"
  local host="${rest%%/*}"
  [[ -z "${host}" ]] && return 1
  [[ "${host}" =~ [^A-Za-z0-9.-] ]] && return 1
  [[ "${host}" == *".."* ]] && return 1
  return 0
}

prompt_https_url() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local input=""
  while true; do
    read -rp "$(printf "%s [%s]: " "$prompt" "$default")" input || true
    if [[ -z "${input}" ]]; then
      input="$default"
    fi
    input="$(normalize_url "${input}")"
    if is_valid_https_domain_url "${input}"; then
      printf -v "${var_name}" "%s" "${input}"
      break
    fi
    echo "Secure Base URL must be HTTPS and use a domain name (for example: https://shop.example.com/)." >&2
  done
}

is_valid_timezone() {
  local tz="$1"
  [[ -z "${tz}" ]] && return 1
  if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl list-timezones 2>/dev/null | grep -Fxq "${tz}"; then
      return 0
    fi
  fi
  [[ -f "/usr/share/zoneinfo/${tz}" ]]
}

prompt_timezone() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local input=""
  while true; do
    read -rp "$(printf "%s [%s]: " "$prompt" "$default")" input || true
    if [[ -z "${input}" ]]; then
      input="$default"
    fi
    if is_valid_timezone "${input}"; then
      printf -v "${var_name}" "%s" "${input}"
      break
    fi
    echo "Invalid timezone. Run 'bin/magento info:timezone:list' for valid identifiers (e.g. Europe/Warsaw, UTC)." >&2
  done
}

ensure_mariadb_repo() {
  local target="${MARIADB_TARGET_VERSION}"
  [[ -z "${target}" ]] && return
  if apt-cache policy mariadb-server 2>/dev/null | grep -Eq "${target//./\\.}"; then
    return
  fi
  msg_info "Configuring MariaDB ${target} repository"
  local repo_script="/tmp/mariadb_repo_setup.sh"
  local repo_url="https://downloads.mariadb.com/MariaDB/mariadb_repo_setup"
  if ! curl -fsSL -o "${repo_script}" "${repo_url}"; then
    msg_error "Failed to download MariaDB repo setup script"
    exit 1
  fi
  chmod +x "${repo_script}"
  local os_id="debian"
  local os_version="12"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-${os_id}}"
    os_version="${VERSION_ID:-${os_version}}"
  fi
  # MariaDB repo setup does not yet support Debian 13; fall back to 12
  if [[ "${os_id}" == "debian" && "${os_version}" =~ ^13 ]]; then
    os_version="12"
  fi
  if ! "${repo_script}" --mariadb-server-version="${target}" --os-type="${os_id}" --os-version="${os_version}" >/dev/null; then
    msg_error "MariaDB repo setup script failed"
    exit 1
  fi
  rm -f "${repo_script}"
  $STD apt-get update
  msg_ok "MariaDB ${target} repository configured"
}

collect_magento_install_preferences() {
  MAGENTO_BASE_URL="$(normalize_url "${MAGENTO_BASE_URL}")"
  MAGENTO_BASE_URL_SECURE="$(normalize_url "${MAGENTO_BASE_URL_SECURE}")"
  MAGENTO_SEARCH_ENGINE="${MAGENTO_SEARCH_ENGINE,,}"
  if [[ -z "${MAGENTO_ADMIN_PASSWORD}" ]]; then
    MAGENTO_ADMIN_PASSWORD="$(generate_random_password 16)"
  fi

  if [[ ! -t 0 ]]; then
    if ! is_valid_https_domain_url "${MAGENTO_BASE_URL_SECURE}"; then
      msg_error "MAGENTO_BASE_URL_SECURE must be an HTTPS URL with a domain name (e.g. https://shop.example.com/)."
      exit 1
    fi
    if ! is_valid_timezone "${MAGENTO_TIMEZONE}"; then
      msg_warn "Invalid MAGENTO_TIMEZONE '${MAGENTO_TIMEZONE}', defaulting to UTC."
      MAGENTO_TIMEZONE="UTC"
    fi
    if ! is_valid_password "${MAGENTO_ADMIN_PASSWORD}"; then
      msg_warn "Provided admin password does not meet Magento complexity requirements. Generating a new one."
      MAGENTO_ADMIN_PASSWORD="$(generate_random_password 16)"
    fi
    return
  fi

  echo -e "\n${INFO}${YW} Magento configuration:${CL}"
  prompt_with_default "Preferred Base URL" "${MAGENTO_BASE_URL}" MAGENTO_BASE_URL
  prompt_https_url "Secure Base URL (must be HTTPS with a domain)" "${MAGENTO_BASE_URL_SECURE}" MAGENTO_BASE_URL_SECURE
  prompt_with_default "Admin email" "${MAGENTO_ADMIN_EMAIL}" MAGENTO_ADMIN_EMAIL
  prompt_with_default "Admin first name" "${MAGENTO_ADMIN_FIRSTNAME}" MAGENTO_ADMIN_FIRSTNAME
  prompt_with_default "Admin last name" "${MAGENTO_ADMIN_LASTNAME}" MAGENTO_ADMIN_LASTNAME
  prompt_with_default "Admin username" "${MAGENTO_ADMIN_USER}" MAGENTO_ADMIN_USER
  prompt_password_with_policy "Admin password (letters + digits, min 8 chars)" "${MAGENTO_ADMIN_PASSWORD}" MAGENTO_ADMIN_PASSWORD
  prompt_with_default "Backend frontname" "${MAGENTO_BACKEND_FRONTNAME}" MAGENTO_BACKEND_FRONTNAME
  prompt_with_default "Language (locale)" "${MAGENTO_LANGUAGE}" MAGENTO_LANGUAGE
  prompt_with_default "Currency" "${MAGENTO_CURRENCY}" MAGENTO_CURRENCY
  prompt_timezone "Timezone" "${MAGENTO_TIMEZONE}" MAGENTO_TIMEZONE
  prompt_with_default "Search engine (opensearch/elasticsearch7)" "${MAGENTO_SEARCH_ENGINE}" MAGENTO_SEARCH_ENGINE
  prompt_with_default "Search host" "${MAGENTO_SEARCH_HOST}" MAGENTO_SEARCH_HOST
  prompt_with_default "Search port" "${MAGENTO_SEARCH_PORT}" MAGENTO_SEARCH_PORT
  prompt_with_default "Search index prefix" "${MAGENTO_SEARCH_INDEX_PREFIX}" MAGENTO_SEARCH_INDEX_PREFIX

  MAGENTO_BASE_URL="$(normalize_url "${MAGENTO_BASE_URL}")"
  MAGENTO_BASE_URL_SECURE="$(normalize_url "${MAGENTO_BASE_URL_SECURE}")"
  MAGENTO_SEARCH_ENGINE="${MAGENTO_SEARCH_ENGINE,,}"
}

ensure_magento_repo_keys() {
  if [[ -z "${MAGENTO_REPO_PUBLIC_KEY:-}" || -z "${MAGENTO_REPO_PRIVATE_KEY:-}" ]]; then
    if [[ ! -t 0 ]]; then
      msg_error "Magento repo keys missing. Set MAGENTO_REPO_PUBLIC_KEY and MAGENTO_REPO_PRIVATE_KEY environment variables."
      exit 1
    fi
  fi
  local input=""
  while [[ -z "${MAGENTO_REPO_PUBLIC_KEY:-}" ]]; do
    read -rp "Enter Magento repo public key: " input || true
    MAGENTO_REPO_PUBLIC_KEY="$(printf '%s' "${input}" | tr -d '\r\n')"
  done
  while [[ -z "${MAGENTO_REPO_PRIVATE_KEY:-}" ]]; do
    read -rsp "Enter Magento repo private key: " input || true
    echo
    MAGENTO_REPO_PRIVATE_KEY="$(printf '%s' "${input}" | tr -d '\r\n')"
  done
}

configure_composer_auth() {
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
}

install_magento_via_composer() {
  ensure_magento_repo_keys
  configure_composer_auth
  msg_info "Downloading Magento v${MAGENTO_VERSION} via Composer"
  COMPOSER_ALLOW_SUPERUSER=1 composer create-project \
    --repository-url=https://repo.magento.com/ \
    magento/project-community-edition="${MAGENTO_VERSION}" \
    "${MAGENTO_DIR}"
  msg_ok "Magento downloaded"
}

build_search_args() {
  SEARCH_ARGS=()
  case "${MAGENTO_SEARCH_ENGINE}" in
  opensearch)
    SEARCH_ARGS=(
      --search-engine=opensearch
      --opensearch-host="${MAGENTO_SEARCH_HOST}"
      --opensearch-port="${MAGENTO_SEARCH_PORT}"
      --opensearch-index-prefix="${MAGENTO_SEARCH_INDEX_PREFIX}"
    )
    ;;
  elasticsearch7 | elasticsearch8)
    SEARCH_ARGS=(
      --search-engine="${MAGENTO_SEARCH_ENGINE}"
      --elasticsearch-host="${MAGENTO_SEARCH_HOST}"
      --elasticsearch-port="${MAGENTO_SEARCH_PORT}"
      --elasticsearch-index-prefix="${MAGENTO_SEARCH_INDEX_PREFIX}"
    )
    ;;
  *)
    SEARCH_ARGS=(--search-engine="${MAGENTO_SEARCH_ENGINE}")
    ;;
  esac
}

write_admin_credentials_file() {
  local trimmed_base="${MAGENTO_BASE_URL%/}"
  local admin_url="${trimmed_base}/${MAGENTO_BACKEND_FRONTNAME}"
  cat >/root/.magento_admin_credentials <<EOF
Storefront URL: ${MAGENTO_BASE_URL}
Admin URL: ${admin_url}
Admin Email: ${MAGENTO_ADMIN_EMAIL}
Admin User: ${MAGENTO_ADMIN_USER}
Admin Password: ${MAGENTO_ADMIN_PASSWORD}
EOF
  chmod 600 /root/.magento_admin_credentials
}

run_magento_cli_install() {
  msg_info "Running Magento CLI installer"
  build_search_args
  local disable_modules_args=()
  if [[ -n "${MAGENTO_DISABLE_MODULES:-}" ]]; then
    disable_modules_args=(--disable-modules="${MAGENTO_DISABLE_MODULES}")
  fi
  pushd "${MAGENTO_DIR}" >/dev/null
  chown -R www-data:www-data .
  chmod +x bin/magento
  if ! bin/magento setup:install \
    --base-url="${MAGENTO_BASE_URL}" \
    --base-url-secure="${MAGENTO_BASE_URL_SECURE}" \
    --db-host="localhost" \
    --db-name="${MARIADB_DB_NAME}" \
    --db-user="${MARIADB_DB_USER}" \
    --db-password="${MARIADB_DB_PASS}" \
    --backend-frontname="${MAGENTO_BACKEND_FRONTNAME}" \
    --admin-firstname="${MAGENTO_ADMIN_FIRSTNAME}" \
    --admin-lastname="${MAGENTO_ADMIN_LASTNAME}" \
    --admin-email="${MAGENTO_ADMIN_EMAIL}" \
    --admin-user="${MAGENTO_ADMIN_USER}" \
    --admin-password="${MAGENTO_ADMIN_PASSWORD}" \
    --language="${MAGENTO_LANGUAGE}" \
    --currency="${MAGENTO_CURRENCY}" \
    --timezone="${MAGENTO_TIMEZONE}" \
    --use-rewrites=1 \
    --use-secure="${MAGENTO_USE_SECURE}" \
    --use-secure-admin="${MAGENTO_USE_SECURE_ADMIN}" \
    --session-save=files \
    --cleanup-database \
    --sales-order-increment-prefix="${MAGENTO_SALES_ORDER_PREFIX}" \
    "${disable_modules_args[@]}" \
    "${SEARCH_ARGS[@]}"; then
    popd >/dev/null
    msg_error "Magento CLI installation failed"
    exit 1
  fi
  popd >/dev/null
  write_admin_credentials_file
  msg_ok "Magento CLI install completed"
}

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
PHP_EXT_PACKAGES=(
  "php${PHP_VERSION}-bcmath"
  "php${PHP_VERSION}-curl"
  "php${PHP_VERSION}-gd"
  "php${PHP_VERSION}-intl"
  "php${PHP_VERSION}-mbstring"
  "php${PHP_VERSION}-soap"
  "php${PHP_VERSION}-xml"
  "php${PHP_VERSION}-xsl"
  "php${PHP_VERSION}-zip"
)
PHP_SODIUM_PKG="php${PHP_VERSION}-sodium"
if ! apt-cache show "${PHP_SODIUM_PKG}" >/dev/null 2>&1; then
  if apt-cache show php-sodium >/dev/null 2>&1; then
    PHP_SODIUM_PKG="php-sodium"
  else
    PHP_SODIUM_PKG=""
    msg_warn "libsodium extension package not found for PHP ${PHP_VERSION}; skipping"
  fi
fi
if [[ -n "${PHP_SODIUM_PKG}" ]]; then
  PHP_EXT_PACKAGES+=("${PHP_SODIUM_PKG}")
fi
$STD apt-get install -y "${PHP_EXT_PACKAGES[@]}"
msg_ok "PHP extensions installed"

ensure_mariadb_repo
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

collect_magento_install_preferences
install_magento_via_composer

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

run_magento_cli_install

motd_ssh
customize
cleanup_lxc

msg_ok "Magento storefront ready"
local_admin_url="${MAGENTO_BASE_URL%/}/${MAGENTO_BACKEND_FRONTNAME}"
echo -e "${INFO}${YW} Storefront URL:${CL} ${BGN}${MAGENTO_BASE_URL}${CL}"
echo -e "${INFO}${YW} Admin URL:${CL} ${BGN}${local_admin_url}${CL}"
echo -e "${INFO}${YW} Admin user:${CL} ${BGN}${MAGENTO_ADMIN_USER}${CL}"
echo -e "${INFO}${YW} Admin password:${CL} ${BGN}${MAGENTO_ADMIN_PASSWORD}${CL}"
echo -e "${INFO}${YW} Admin email:${CL} ${BGN}${MAGENTO_ADMIN_EMAIL}${CL}"
echo -e "${INFO}${YW} Credentials saved:${CL} ${BGN}/root/.magento_admin_credentials${CL}"
echo -e "${INFO}${YW} DB credentials:${CL} saved in ${BGN}/root/.magento_db_credentials${CL}"
