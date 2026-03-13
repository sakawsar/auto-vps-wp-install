# 🚀 WordPress Auto-Installer

A single shell script that fully automates WordPress installation on **Ubuntu / Debian** servers with NGINX, MySQL, PHP-FPM, Let's Encrypt SSL, and WP-CLI. Supports installing **multiple sites in one run**.

---

## ✨ Features

- 🌐 **Multi-domain support** — install multiple WordPress sites in a single run using a comma-separated list
- 🔒 **Free SSL** — automatic HTTPS via Certbot + Let's Encrypt
- 🤖 **Subdomain-aware** — skips `www.` alias for subdomains automatically
- 🗄️ **MySQL setup** — creates a dedicated database and user per domain
- ⚙️ **NGINX config** — copies your placeholder config and substitutes domain/webroot tokens
- 🔑 **Fresh secret keys** — pulls live salts from the WordPress API and injects them via `awk`
- 🔐 **Hardened permissions** — applies production-ready file/folder permissions
- ✅ **Full summary** — prints Admin URL, credentials and DB info for every site after install

---

## 📋 Requirements

| Requirement | Notes |
|---|---|
| OS | Ubuntu 20.04 / 22.04 / 24.04 or Debian equivalent |
| User | Must be run as **root** (`sudo`) |
| DNS | Domain A record must already point to the server IP |
| NGINX placeholder | `/etc/nginx/sites-available/placeholder` must exist (see below) |
| Ports | 80 and 443 open in firewall |

---

## 🛠️ Installation

### ⚡ One-liner (recommended for VPS)

SSH into your server and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sakawsar/auto-vps-wp-install/main/install.sh)
```

> Requires `curl`. Most Ubuntu/Debian servers have it pre-installed. Run as **root** or prefix with `sudo`.

### 📦 Manual install

```bash
# Clone the repo
git clone https://github.com/sakawsar/auto-vps-wp-install.git
cd auto-vps-wp-install

# Run as root
sudo bash install.sh
```

---

## 💬 Prompts

The script will ask for the following information interactively:

| Prompt | Example | Notes |
|---|---|---|
| Domain name(s) | `example.com` or `example.com, blog.io` | Comma-separated for multiple sites |
| Admin email | `admin@example.com` | Used for WP admin and Certbot |
| Admin username | `admin` | WordPress login username |
| Admin password | `••••••••` | Hidden input |
| MySQL DB password | `••••••••` | Shared across all sites |

A confirmation review is shown before the installation begins.

---

## 📁 NGINX Placeholder

Before running the script, create your NGINX template at:

```
/etc/nginx/sites-available/placeholder
```

Use these **exact tokens** — the script replaces them with real values:

| Token | Replaced with |
|---|---|
| `PLACEHOLDER_DOMAIN` | Domain (+ `www.domain` for apex domains) |
| `PLACEHOLDER_WEBROOT` | `/var/www/<domain>` |

**Example placeholder:**

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name PLACEHOLDER_DOMAIN;
    root PLACEHOLDER_WEBROOT;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
```

---

## 🔄 What the Script Does (Step by Step)

```
1. Collect inputs         — prompts for domains, credentials, DB password
2. Install WP-CLI         — downloads wp-cli.phar if not already present
   ┌── Per domain loop ──────────────────────────────────────────────────┐
3. │ Download WordPress   — latest.zip → /var/www/<domain>              │
4. │ Configure NGINX      — copies placeholder, replaces tokens, symlinks│
5. │ Install SSL          — certbot --nginx (+ www for apex domains)     │
6. │ Create MySQL DB      — database + dedicated user per domain         │
7. │ Configure wp-config  — DB credentials + fresh secret keys via awk  │
8. │ Install WordPress    — wp core install via WP-CLI                   │
9. │ Set permissions      — hardened ownership and chmod                 │
   └────────────────────────────────────────────────────────────────────┘
11. Print summary         — Admin URL, username, password for each site
```

---

## 🔐 File Permissions Applied

| Path | Dirs | Files | Reason |
|---|---|---|---|
| All WP files | `755` | `644` | Standard web-readable |
| `wp-admin/` | `750` | `640` | No world access |
| `wp-includes/` | `750` | `640` | Core — no world read |
| `wp-content/uploads/` | `775` | `664` | www-data must write uploads |
| `wp-config.php` | — | `640` | Credentials protected |
| `.htaccess` | — | `644` | Must be web-readable |

All files are owned by **`www-data:www-data`**.

---

## 📦 Auto-Installed Packages

```
nginx  mysql-server  php-fpm  php-mysql  php-curl  php-gd
php-mbstring  php-xml  php-xmlrpc  php-zip  php-soap  php-intl
curl  unzip  certbot  python3-certbot-nginx  wget
```

> **Note:** Package installation is included in the script but commented out by default (`# install_packages`). Uncomment it in `main()` if you need the script to install dependencies automatically.

---

## 📊 Example Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Installing: example.com
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO]  Copying placeholder NGINX config to /etc/nginx/sites-available/example.com...
[INFO]  Apex domain detected — adding www.example.com alias.
[OK]    NGINX configured and reloaded.
[OK]    SSL certificate installed.
[OK]    Database and user created.
[OK]    WordPress secret keys injected.
[OK]    WordPress core installed successfully.
[OK]    File permissions applied.

══════════════════════════════════════════════════════
   ✅  WordPress Installation Complete!
══════════════════════════════════════════════════════

── example.com ────────────────────────────────────────
  Site URL    : https://example.com
  Admin URL   : https://example.com/wp-admin
  Username    : admin
  Password    : YourPassword
  Admin Email : admin@example.com
  Web Root    : /var/www/example.com
  NGINX Config: /etc/nginx/sites-available/example.com
  Database    : example_com (user: example_com_user)
```

---

## ⚠️ Security Notes

- Run on a **fresh server** where possible
- Store credentials in a **password manager**, not in this repo
- Remove or restrict access to `install.sh` after use
- `wp-config.php` is set to `640` — verify your PHP-FPM runs as `www-data`

---

## 📄 License

MIT
