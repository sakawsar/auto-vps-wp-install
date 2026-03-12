#!/usr/bin/env bash
# =============================================================================
#  WordPress Auto-Installer
#  Installs WordPress on Ubuntu/Debian with NGINX, MySQL, PHP, and Certbot SSL
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Try: sudo $0"
}

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-false}"
  local value=""

  while [[ -z "$value" ]]; do
    if [[ "$secret" == "true" ]]; then
      read -rsp "${BOLD}${prompt_text}:${RESET} " value
      echo
    else
      read -rp "${BOLD}${prompt_text}:${RESET} " value
    fi
    [[ -z "$value" ]] && warn "This field cannot be empty. Please try again."
  done

  printf -v "$var_name" '%s' "$value"
}

# ── Collect user input ────────────────────────────────────────────────────────
collect_inputs() {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}   WordPress Automated Installer           ${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n"

  prompt DOMAIN        "Domain name (e.g. example.com)"
  prompt ADMIN_EMAIL   "WordPress admin email"
  prompt ADMIN_USER    "WordPress admin username"
  prompt ADMIN_PASS    "WordPress admin password" true
  prompt DB_NAME       "MySQL database name"
  prompt DB_PASS       "MySQL database password" true

  # Derive safe identifiers
  DB_USER="${DB_NAME}_user"
  WEBROOT="/var/www/${DOMAIN}"
  NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
  NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

  echo
  echo -e "${BOLD}Review your settings:${RESET}"
  echo -e "  Domain        : ${GREEN}${DOMAIN}${RESET}"
  echo -e "  Web root      : ${GREEN}${WEBROOT}${RESET}"
  echo -e "  Admin email   : ${GREEN}${ADMIN_EMAIL}${RESET}"
  echo -e "  Admin user    : ${GREEN}${ADMIN_USER}${RESET}"
  echo -e "  Database name : ${GREEN}${DB_NAME}${RESET}"
  echo -e "  Database user : ${GREEN}${DB_USER}${RESET}"
  echo

  read -rp "${BOLD}Proceed with installation? [y/N]:${RESET} " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || error "Installation cancelled by user."
}

# ── Install system packages ───────────────────────────────────────────────────
install_packages() {
  info "Updating package lists..."
  apt-get update -qq

  info "Installing NGINX, PHP, MySQL, Certbot and dependencies..."
  apt-get install -y -qq \
    nginx \
    mysql-server \
    php-fpm \
    php-mysql \
    php-curl \
    php-gd \
    php-mbstring \
    php-xml \
    php-xmlrpc \
    php-zip \
    php-soap \
    php-intl \
    curl \
    unzip \
    certbot \
    python3-certbot-nginx \
    wget

  success "Packages installed."
}

# ── Download and unzip WordPress ──────────────────────────────────────────────
install_wordpress_files() {
  info "Downloading latest WordPress..."
  local tmp_zip="/tmp/wordpress-latest.zip"

  wget -q "https://wordpress.org/latest.zip" -O "$tmp_zip"

  info "Creating web root: ${WEBROOT}"
  mkdir -p "$WEBROOT"

  info "Extracting WordPress files..."
  unzip -q "$tmp_zip" -d /tmp/
  cp -r /tmp/wordpress/. "$WEBROOT/"
  rm -rf /tmp/wordpress "$tmp_zip"

  # Initial ownership – fine-grained permissions applied later by set_permissions
  chown -R www-data:www-data "$WEBROOT"

  success "WordPress files extracted to ${WEBROOT}."
}

# ── Create NGINX virtual host (copied from placeholder) ───────────────────────
configure_nginx() {
  local placeholder="/etc/nginx/sites-available/placeholder"

  [[ -f "$placeholder" ]] || error "Placeholder config not found: ${placeholder}. Please create it before running this script."

  # Subdomain detection: count the dots in the domain.
  # apex domain  → example.com        (1 dot)  → add www.example.com alias
  # subdomain    → sub.example.com    (2+ dots) → no www alias
  local dot_count server_name_value
  dot_count=$(awk -F'.' '{print NF-1}' <<< "$DOMAIN")

  if [[ "$dot_count" -ge 2 ]]; then
    # Subdomain — use only the bare domain, no www prefix
    server_name_value="${DOMAIN}"
    info "Subdomain detected — skipping www alias."
  else
    # Apex domain — include www alias
    server_name_value="${DOMAIN} www.${DOMAIN}"
    info "Apex domain detected — adding www.${DOMAIN} alias."
  fi

  info "Copying placeholder NGINX config to ${NGINX_CONF}..."
  cp "$placeholder" "$NGINX_CONF"

  # Replace placeholder tokens with real values.
  # The placeholder file should use these tokens:
  #   PLACEHOLDER_DOMAIN  → domain (and www alias when applicable)
  #   PLACEHOLDER_WEBROOT → absolute path to the web root
  sed -i \
    -e "s|PLACEHOLDER_DOMAIN|${server_name_value}|g" \
    -e "s|PLACEHOLDER_WEBROOT|${WEBROOT}|g" \
    "$NGINX_CONF"

  info "Enabling site via symlink: ${NGINX_LINK}..."
  ln -sf "$NGINX_CONF" "$NGINX_LINK"

  nginx -t || error "NGINX configuration test failed. Please check ${NGINX_CONF}."
  systemctl reload nginx
  success "NGINX configured and reloaded."
}

# ── Obtain SSL certificate with Certbot ───────────────────────────────────────
install_ssl() {
  local dot_count certbot_cmd
  dot_count=$(awk -F'.' '{print NF-1}' <<< "$DOMAIN")

  certbot_cmd="certbot --nginx -d ${DOMAIN}"
  if [[ "$dot_count" -lt 2 ]]; then
    certbot_cmd+=" -d www.${DOMAIN}"
    info "Requesting SSL certificate for ${DOMAIN} and www.${DOMAIN}..."
  else
    info "Requesting SSL certificate for ${DOMAIN} (subdomain — no www)..."
  fi

  eval "$certbot_cmd" \
    --non-interactive \
    --agree-tos \
    --redirect \
    --email "${ADMIN_EMAIL}" || warn "Certbot failed. You can run it manually later."

  success "SSL certificate installed."
}

# ── Create MySQL database and user ────────────────────────────────────────────
setup_database() {
  info "Creating MySQL database '${DB_NAME}' and user '${DB_USER}'..."

  mysql --user=root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  success "Database and user created."
}

# ── Install WP-CLI ────────────────────────────────────────────────────────────
install_wp_cli() {
  if command -v wp &>/dev/null; then
    info "WP-CLI already installed, skipping."
    return
  fi

  info "Installing WP-CLI..."
  wget -q "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" -O /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
  success "WP-CLI installed."
}

# ── Configure wp-config.php ───────────────────────────────────────────────────
configure_wp() {
  info "Generating wp-config.php..."

  cp "${WEBROOT}/wp-config-sample.php" "${WEBROOT}/wp-config.php"

  # Replace database credentials
  sed -i "s/database_name_here/${DB_NAME}/"    "${WEBROOT}/wp-config.php"
  sed -i "s/username_here/${DB_USER}/"          "${WEBROOT}/wp-config.php"
  sed -i "s/password_here/${DB_PASS}/"          "${WEBROOT}/wp-config.php"
  sed -i "s/localhost/localhost/"               "${WEBROOT}/wp-config.php"

  # Replace WordPress salts with fresh ones from the API
  info "Fetching fresh WordPress secret keys..."
  local salts
  salts=$(curl -s "https://api.wordpress.org/secret-key/1.1/salt/")
  # Remove existing placeholder salt block and insert fresh keys
  php -r "
    \$config = file_get_contents('${WEBROOT}/wp-config.php');
    \$config = preg_replace(
      '/\/\*\*#@\+\*\/.*?\/\*\*#@-\*\//s',
      addslashes('${salts}'),
      \$config
    );
    file_put_contents('${WEBROOT}/wp-config.php', \$config);
  " 2>/dev/null || warn "Could not auto-replace salts. Update them manually at https://api.wordpress.org/secret-key/1.1/salt/"

  # Set table prefix for slight obscurity
  sed -i "s/\$table_prefix = 'wp_';/\$table_prefix = 'wp_';/" "${WEBROOT}/wp-config.php"

  success "wp-config.php configured."
}

# ── Set hardened WordPress file permissions ───────────────────────────────────
set_permissions() {
  info "Applying hardened file permissions to ${WEBROOT}..."

  # Ownership: everything belongs to www-data
  chown -R www-data:www-data "${WEBROOT}"

  # Directories: 755  (owner rwx, group/others rx)
  find "${WEBROOT}" -type d -exec chmod 755 {} \;

  # Files: 644  (owner rw, group/others r)
  find "${WEBROOT}" -type f -exec chmod 644 {} \;

  # wp-admin: tighten to 750 (no world access)
  chmod 750 "${WEBROOT}/wp-admin"
  find "${WEBROOT}/wp-admin" -type d -exec chmod 750 {} \;
  find "${WEBROOT}/wp-admin" -type f -exec chmod 640 {} \;

  # wp-includes: tighten to 750
  find "${WEBROOT}/wp-includes" -type d -exec chmod 750 {} \;
  find "${WEBROOT}/wp-includes" -type f -exec chmod 640 {} \;

  # wp-content/uploads: www-data needs to write uploaded files
  if [[ -d "${WEBROOT}/wp-content/uploads" ]]; then
    find "${WEBROOT}/wp-content/uploads" -type d -exec chmod 775 {} \;
    find "${WEBROOT}/wp-content/uploads" -type f -exec chmod 664 {} \;
  else
    mkdir -p "${WEBROOT}/wp-content/uploads"
    chmod 775 "${WEBROOT}/wp-content/uploads"
    chown www-data:www-data "${WEBROOT}/wp-content/uploads"
  fi

  # wp-config.php: owner rw only — no group/world read
  if [[ -f "${WEBROOT}/wp-config.php" ]]; then
    chown www-data:www-data "${WEBROOT}/wp-config.php"
    chmod 640 "${WEBROOT}/wp-config.php"
  fi

  # .htaccess (if present)
  if [[ -f "${WEBROOT}/.htaccess" ]]; then
    chmod 644 "${WEBROOT}/.htaccess"
  fi

  success "File permissions applied."
}

# ── Run WordPress installation via WP-CLI ─────────────────────────────────────
run_wp_install() {
  local site_url="https://${DOMAIN}"

  info "Running WordPress core install..."
  sudo -u www-data wp core install \
    --path="${WEBROOT}" \
    --url="${site_url}" \
    --title="${DOMAIN}" \
    --admin_user="${ADMIN_USER}" \
    --admin_password="${ADMIN_PASS}" \
    --admin_email="${ADMIN_EMAIL}" \
    --skip-email \
    --allow-root

  success "WordPress core installed successfully."
}

# ── Final summary ─────────────────────────────────────────────────────────────
print_summary() {
  echo
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}   ✅  WordPress Installation Complete!               ${RESET}"
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
  echo
  echo -e "  ${BOLD}Site URL     :${RESET} https://${DOMAIN}"
  echo -e "  ${BOLD}Admin URL    :${RESET} ${CYAN}https://${DOMAIN}/wp-admin${RESET}"
  echo -e "  ${BOLD}Username     :${RESET} ${GREEN}${ADMIN_USER}${RESET}"
  echo -e "  ${BOLD}Password     :${RESET} ${GREEN}${ADMIN_PASS}${RESET}"
  echo -e "  ${BOLD}Admin Email  :${RESET} ${GREEN}${ADMIN_EMAIL}${RESET}"
  echo
  echo -e "  ${BOLD}Web Root     :${RESET} ${WEBROOT}"
  echo -e "  ${BOLD}NGINX Config :${RESET} ${NGINX_CONF}"
  echo -e "  ${BOLD}Database     :${RESET} ${DB_NAME} (user: ${DB_USER})"
  echo
  echo -e "${YELLOW}  ⚠  Keep your credentials safe and remove this script if storing in a public repo.${RESET}"
  echo
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
  require_root
  collect_inputs
#   install_packages
  install_wordpress_files
  configure_nginx
  install_ssl
  setup_database
  install_wp_cli
  configure_wp
  run_wp_install
  set_permissions
  print_summary
}

main "$@"
