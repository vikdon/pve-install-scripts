# pve-install-scripts

This repository contains Proxmox VE helper scripts that provision ready-to-use LXC containers for popular ecommerce platforms. Application installers live under `ct/`, while reusable helper functions are stored in `misc/`.

## Usage

Run the scripts directly from GitHub by downloading them with `curl` and piping to `bash` inside a Proxmox shell session.

### OpenCart

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/vikdon/pve-install-scripts/refs/heads/main/ct/opencart.sh)"
```

**What gets installed**
- Debian LXC with Apache/PHP/MariaDB, tuned for OpenCart
- Latest stable OpenCart release (override via `var_oc_version`)
- Database credentials stored in `/root/.opencart_db_credentials`

### Magento

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/vikdon/pve-install-scripts/refs/heads/main/ct/magento.sh)"
```

**What gets installed**
- Debian LXC with Apache, PHP 8.2 stack, MariaDB, Redis-ready configuration
- Full Magento codebase via Composer (prompts for repo keys, admin user, base URL, search endpoint)
- Automatic `bin/magento setup:install` run; storefront/admin URLs and credentials saved in `/root/.magento_admin_credentials`

> Ensure your user has permission to create LXC containers and that Proxmox VE runs a supported version before executing the scripts.
