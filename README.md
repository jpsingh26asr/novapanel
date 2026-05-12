# NovaPanel

Open-source cPanel-style web hosting control panel for Ubuntu 22.04 / 24.04.

![Admin Panel](screenshots/admin-dashboard.png)

## Features

- Multi-user hosting accounts (real Linux system users)
- Per-user web roots at `~/public_html/`
- Isolated PHP-FPM pools per user
- Apache vhosts with SSL (Let's Encrypt)
- Addon domains, subdomains, parked domains
- MariaDB databases with per-user prefix
- File manager, cron jobs, SSH keys
- FTP (vsftpd) + SFTP (OpenSSH chroot)
- Admin panel (port 8083) + User panel (port 8084)
- phpMyAdmin integration

## Requirements

- Ubuntu 22.04 or 24.04 (fresh install recommended)
- Minimum 1 GB RAM, 20 GB disk
- Root or sudo access

## Installation

```bash
# Step 1 — LAMP stack
sudo bash install/01_install_lamp_server.sh

# Step 2 — WebPanel
sudo bash install/02_install_webpanel.sh
```

Credentials are saved to `/root/.server_credentials`.

## Screenshots

| Admin Panel | User Panel |
|-------------|------------|
| ![Admin](screenshots/admin.png) | ![User](screenshots/user.png) |

## License

GPL-3.0 — see [LICENSE](LICENSE)
