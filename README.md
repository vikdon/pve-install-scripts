# pve-install-scripts

This repository contains Proxmox VE helper scripts that provision ready-to-use LXC containers for popular ecommerce platforms. Application installers live under `ct/`, while reusable helper functions are stored in `misc/`.

## Usage

Run the scripts directly from GitHub by downloading them with `curl` and piping to `bash` inside a Proxmox shell session.

### OpenCart

```bash
bash -c "$(curl -fsSL https://github.com/vikdon/pve-install-scripts/refs/heads/main/ct/opencart.sh)"
```

### Magento

```bash
bash -c "$(curl -fsSL https://github.com/vikdon/pve-install-scripts/refs/heads/main/ct/magento.sh)"
```

> Ensure your user has permission to create LXC containers and that Proxmox VE runs a supported version before executing the scripts.
