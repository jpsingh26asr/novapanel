#!/bin/bash
# =============================================================================
#  01_install_lamp_server.sh  —  LAMP Stack for WebPanel
#  Ubuntu 22.04 / 24.04
#  PHP 8.3 (stable + wide PPA support), Apache2, MariaDB, Redis,
#  Certbot, VSFTPD+SFTP, phpMyAdmin 5.2.3, Fail2Ban, UFW
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
log()  { echo -e "${G}[✔]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[✘]${N} $*"; exit 1; }
hdr()  { echo -e "\n${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"; }

[[ $EUID -ne 0 ]] && die "Run as root:  sudo bash $0"

# ── Settings ──────────────────────────────────────────────────────────────────
PHP_VER="${PHP_VER:-8.3}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)}"
TZ="${TZ:-Asia/Kuwait}"
CRED_FILE="/root/.server_credentials"
LOG="/var/log/lamp_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

hdr "LAMP Stack Installer — PHP ${PHP_VER}"
echo "  Log: $LOG"
echo "  MySQL Root Pass (being set): ${MYSQL_ROOT_PASS}"

# ── 1. System ─────────────────────────────────────────────────────────────────
hdr "1 · System Update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y \
    software-properties-common apt-transport-https ca-certificates gnupg2 \
    curl wget git unzip zip tar gzip bzip2 nano vim \
    htop net-tools dnsutils lsof \
    build-essential openssl \
    ufw fail2ban logrotate cron acl \
    supervisor
log "System packages installed"

# ── 2. Apache2 ────────────────────────────────────────────────────────────────
hdr "2 · Apache2"
apt-get install -y apache2 apache2-utils

for mod in rewrite ssl headers expires deflate \
           proxy proxy_fcgi proxy_http setenvif \
           http2 socache_shmcb actions alias env \
           authz_host vhost_alias; do
    a2enmod "$mod" 2>/dev/null || true
done

cat > /etc/apache2/conf-available/security.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header unset X-Powered-By
EOF
a2enconf security 2>/dev/null || true

# Disable default site
a2dissite 000-default 2>/dev/null || true

systemctl enable apache2 && systemctl restart apache2
log "Apache2 ready"

# ── 3. PHP ────────────────────────────────────────────────────────────────────
hdr "3 · PHP ${PHP_VER}"

# Add Ondřej Surý PPA (most reliable PHP source for Ubuntu)
add-apt-repository ppa:ondrej/php -y
apt-get update -y

# Install core PHP packages — use array so IFS=$'\n\t' doesn't break word splitting
PHP_CORE=(
    "php${PHP_VER}-cli"
    "php${PHP_VER}-fpm"
    "php${PHP_VER}-common"
    "libapache2-mod-php${PHP_VER}"
    "php${PHP_VER}-mysql"
    "php${PHP_VER}-curl"
    "php${PHP_VER}-mbstring"
    "php${PHP_VER}-xml"
    "php${PHP_VER}-zip"
    "php${PHP_VER}-bcmath"
    "php${PHP_VER}-gd"
    "php${PHP_VER}-intl"
    "php${PHP_VER}-opcache"
    "php${PHP_VER}-readline"
)
apt-get install -y "${PHP_CORE[@]}"
log "Core PHP extensions installed"

# Optional extensions — install one by one, skip if unavailable
PHP_OPTIONAL=(
    "php${PHP_VER}-redis"
    "php${PHP_VER}-memcached"
    "php${PHP_VER}-imagick"
    "php${PHP_VER}-apcu"
    "php${PHP_VER}-sqlite3"
    "php${PHP_VER}-pgsql"
    "php${PHP_VER}-soap"
    "php${PHP_VER}-imap"
    "php${PHP_VER}-ldap"
    "php${PHP_VER}-bz2"
)
for pkg in "${PHP_OPTIONAL[@]}"; do
    apt-get install -y "$pkg" 2>/dev/null && log "  + $pkg" || warn "  skip $pkg (not in PPA for PHP ${PHP_VER})"
done

# Tune php.ini for both FPM and CLI
tune_ini() {
    local f="$1" mem="$2" exec_t="$3"
    [[ -f "$f" ]] || return
    sed -i "s|^memory_limit.*|memory_limit = ${mem}|"           "$f"
    sed -i "s|^max_execution_time.*|max_execution_time = ${exec_t}|" "$f"
    sed -i "s|^upload_max_filesize.*|upload_max_filesize = 512M|" "$f"
    sed -i "s|^post_max_size.*|post_max_size = 512M|"           "$f"
    # date.timezone may be commented out
    if grep -q "^;date.timezone" "$f"; then
        sed -i "s|^;date.timezone.*|date.timezone = ${TZ}|" "$f"
    elif grep -q "^date.timezone" "$f"; then
        sed -i "s|^date.timezone.*|date.timezone = ${TZ}|" "$f"
    else
        echo "date.timezone = ${TZ}" >> "$f"
    fi
    sed -i "s|^expose_php.*|expose_php = Off|"         "$f"
    sed -i "s|^display_errors.*|display_errors = Off|" "$f"
    sed -i "s|^log_errors.*|log_errors = On|"          "$f"
    # OPcache
    if ! grep -q "opcache.enable" "$f"; then
        cat >> "$f" <<'OPC'

; OPcache
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.revalidate_freq=2
OPC
    fi
}
tune_ini "/etc/php/${PHP_VER}/cli/php.ini"     "512M" "300"
tune_ini "/etc/php/${PHP_VER}/fpm/php.ini"     "256M" "120"
tune_ini "/etc/php/${PHP_VER}/apache2/php.ini" "256M" "120" 2>/dev/null || true

# Global FPM pool (www-data) — used by the panel itself
cat > "/etc/php/${PHP_VER}/fpm/pool.d/www.conf" <<EOF
[www]
user  = www-data
group = www-data
listen = /run/php/php${PHP_VER}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660
pm = dynamic
pm.max_children     = 20
pm.start_servers    = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests     = 500
EOF

update-alternatives --set php        "/usr/bin/php${PHP_VER}"        2>/dev/null || true
update-alternatives --set php-config "/usr/bin/php-config${PHP_VER}" 2>/dev/null || true
a2dismod  "php${PHP_VER}" 2>/dev/null || true  # Use FPM, not mod_php
a2enmod   proxy_fcgi setenvif 2>/dev/null || true
a2enconf  "php${PHP_VER}-fpm" 2>/dev/null || true
systemctl enable "php${PHP_VER}-fpm"
systemctl restart "php${PHP_VER}-fpm"
systemctl reload apache2
log "PHP ${PHP_VER} ready — $(php -v 2>/dev/null | head -1)"

# ── 4. Composer ───────────────────────────────────────────────────────────────
hdr "4 · Composer"
if ! command -v composer &>/dev/null; then
    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" = "$ACTUAL_CHECKSUM" ]; then
        php composer-setup.php --quiet
        mv composer.phar /usr/local/bin/composer
        chmod +x /usr/local/bin/composer
    else
        warn "Composer checksum mismatch — skipping (install manually later)"
    fi
    rm -f composer-setup.php
fi
log "Composer: $(composer --version 2>/dev/null | head -1 || echo 'not installed')"

# ── 5. MariaDB ────────────────────────────────────────────────────────────────
hdr "5 · MariaDB"
apt-get install -y mariadb-server mariadb-client
systemctl enable mariadb && systemctl start mariadb

# ── MariaDB root password setup ───────────────────────────────────────────────
# MariaDB 10.4+ changed authentication significantly:
#   - mysql.user is now a VIEW (not a real table) — UPDATE fails with HY000
#   - Root uses unix_socket plugin by default (no password on fresh install)
#   - ALTER USER is the ONLY correct way to set the password
#   - Do NOT use: UPDATE mysql.user, mysqladmin password, or SET PASSWORD
#
# The correct sequence for ALL MariaDB versions (10.3 / 10.4 / 10.5 / 10.6 / 11.x):
#   1. Connect as root without password (unix_socket auth, works as root OS user)
#   2. ALTER USER to switch to mysql_native_password + set the password
#   3. Remove insecure defaults
#   4. FLUSH PRIVILEGES

mysql -u root <<SQL
-- Step 1: Set root password using ALTER USER (works on MariaDB 10.3+)
-- This switches from unix_socket to password auth and sets the password in one command
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';

-- Step 2: Remove insecure defaults
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

# Verify password auth now works
if mysql -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 'password_ok';" 2>/dev/null | grep -q "password_ok"; then
    log "MariaDB root password verified"
else
    # On some systems ALTER USER switches plugin but still allows socket auth —
    # try mysqladmin as a belt-and-suspenders fallback
    mysqladmin -u root password "${MYSQL_ROOT_PASS}" 2>/dev/null || true
    if mysql -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" 2>/dev/null; then
        log "MariaDB root password set via mysqladmin"
    else
        warn "MariaDB password verification failed — check manually: mysql -u root"
    fi
fi

# Write /root/.my.cnf so all subsequent mysql commands work without -p
cat > /root/.my.cnf <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASS}
host=localhost
EOF
chmod 600 /root/.my.cnf
log "MariaDB root credentials saved to /root/.my.cnf"

# Performance tuning
cat > /etc/mysql/mariadb.conf.d/99-webpanel.cnf <<'EOF'
[mysqld]
innodb_buffer_pool_size        = 256M
innodb_log_file_size           = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method            = O_DIRECT
max_connections                = 300
thread_cache_size              = 16
table_open_cache               = 400
query_cache_type               = 0
character-set-server           = utf8mb4
collation-server               = utf8mb4_unicode_ci
local_infile                   = 0
slow_query_log                 = 1
slow_query_log_file            = /var/log/mysql/slow.log
long_query_time                = 2
EOF
systemctl restart mariadb
log "MariaDB secured and tuned — root password set"

# ── 6. Redis ──────────────────────────────────────────────────────────────────
hdr "6 · Redis"
apt-get install -y redis-server
sed -i 's/^supervised no/supervised systemd/'              /etc/redis/redis.conf 2>/dev/null || true
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/'          /etc/redis/redis.conf 2>/dev/null || true
sed -i 's/^# maxmemory-policy.*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf 2>/dev/null || true
systemctl enable redis-server && systemctl restart redis-server
log "Redis ready"

# ── 7. Memcached ──────────────────────────────────────────────────────────────
hdr "7 · Memcached"
apt-get install -y memcached 2>/dev/null || true
systemctl enable memcached && systemctl start memcached 2>/dev/null || true
log "Memcached ready"

# ── 8. Node.js LTS ────────────────────────────────────────────────────────────
hdr "8 · Node.js"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - 2>/dev/null || true
    apt-get install -y nodejs 2>/dev/null || true
fi
node_ver="$(node -v 2>/dev/null || echo 'not installed')"
log "Node: $node_ver"

# ── 9. Certbot ────────────────────────────────────────────────────────────────
hdr "9 · Certbot"
apt-get install -y certbot python3-certbot-apache
# Add auto-renew cron (idempotent)
( crontab -l 2>/dev/null | grep -v "certbot renew"; \
  echo "0 3 * * * /usr/bin/certbot renew --quiet --deploy-hook 'systemctl reload apache2 2>/dev/null || true'" ) | crontab -
log "Certbot ready"

# ── 10. VSFTPD ────────────────────────────────────────────────────────────────
hdr "10 · VSFTPD (FTP — chrooted per user)"
apt-get install -y vsftpd

# Auto-detect public IP for passive mode
SERVER_PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
pasv_address=${SERVER_PUBLIC_IP}
pasv_addr_resolve=NO
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
idle_session_timeout=600
data_connection_timeout=300
max_clients=100
max_per_ip=5
ls_recurse_enable=NO
EOF

touch /etc/vsftpd.userlist
systemctl enable vsftpd && systemctl restart vsftpd
log "VSFTPD ready (passive IP: ${SERVER_PUBLIC_IP})"

# ── 11. SFTP chroot (OpenSSH) ─────────────────────────────────────────────────
hdr "11 · SFTP Chroot via OpenSSH"
groupadd sftp-users 2>/dev/null || true

if ! grep -q "Match Group sftp-users" /etc/ssh/sshd_config; then
    cat >> /etc/ssh/sshd_config <<'SSHEOF'

# WebPanel SFTP chroot — DO NOT EDIT MANUALLY
Match Group sftp-users
    ChrootDirectory /home/%u
    ForceCommand internal-sftp -l INFO
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
SSHEOF
fi
sshd -t && systemctl reload sshd 2>/dev/null || warn "sshd config test failed — check /etc/ssh/sshd_config"
log "SFTP chroot configured"

# ── 12. Postfix ───────────────────────────────────────────────────────────────
hdr "12 · Postfix"
debconf-set-selections <<< "postfix postfix/mailname string $(hostname -f 2>/dev/null || hostname)"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
apt-get install -y postfix mailutils 2>/dev/null || true
systemctl enable postfix && systemctl start postfix 2>/dev/null || true
log "Postfix ready"

# ── 13. phpMyAdmin 5.2.3 ──────────────────────────────────────────────────────
hdr "13 · phpMyAdmin 5.2.3"
PMA_VER="5.2.3"
PMA_DIR="/opt/phpmyadmin"

if [[ ! -d "$PMA_DIR" ]]; then
    PMA_URL="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VER}/phpMyAdmin-${PMA_VER}-english.zip"
    PMA_ZIP="/tmp/phpmyadmin.zip"

    echo "  Downloading phpMyAdmin ${PMA_VER}..."
    if wget -q --show-progress "$PMA_URL" -O "$PMA_ZIP" 2>/dev/null || \
       curl -L -o "$PMA_ZIP" "$PMA_URL" 2>/dev/null; then
        unzip -q "$PMA_ZIP" -d /opt/ 2>/dev/null || true
        # Handle both naming conventions
        if [[ -d "/opt/phpMyAdmin-${PMA_VER}-english" ]]; then
            mv "/opt/phpMyAdmin-${PMA_VER}-english" "$PMA_DIR"
        elif [[ -d "/opt/phpMyAdmin-${PMA_VER}-all-languages" ]]; then
            mv "/opt/phpMyAdmin-${PMA_VER}-all-languages" "$PMA_DIR"
        fi
        rm -f "$PMA_ZIP"
        log "phpMyAdmin downloaded and extracted"
    else
        warn "phpMyAdmin download failed."
        warn "Manual install: wget '${PMA_URL}' -O /tmp/pma.zip && unzip /tmp/pma.zip -d /opt/ && mv /opt/phpMyAdmin-${PMA_VER}-english ${PMA_DIR}"
    fi
fi

# Configure phpMyAdmin if directory exists
if [[ -d "$PMA_DIR" ]]; then
    # Create config from sample
    if [[ ! -f "$PMA_DIR/config.inc.php" ]]; then
        cp "$PMA_DIR/config.sample.inc.php" "$PMA_DIR/config.inc.php" 2>/dev/null || true
    fi
    # Set blowfish secret
    BF="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 32)"
    sed -i "s|\\\$cfg\['blowfish_secret'\] = ''|\\\$cfg['blowfish_secret'] = '${BF}'|" "$PMA_DIR/config.inc.php" 2>/dev/null || true
    # Create temp dir
    mkdir -p "$PMA_DIR/tmp"
    chown -R www-data:www-data "$PMA_DIR"
    chmod -R 755 "$PMA_DIR"
    chmod 640 "$PMA_DIR/config.inc.php"
    log "phpMyAdmin configured at $PMA_DIR"
else
    warn "phpMyAdmin dir not found — panel will still work, phpMyAdmin link will 404"
    mkdir -p "$PMA_DIR"
    echo "<?php echo '<h2>phpMyAdmin not installed</h2><p>Place phpMyAdmin files here: $PMA_DIR</p>';" > "$PMA_DIR/index.php"
    chown -R www-data:www-data "$PMA_DIR"
fi

# ── 14. /etc/skel — hosting directory template ────────────────────────────────
hdr "14 · /etc/skel (hosting directory template)"
mkdir -p /etc/skel/public_html/{subdomains,addons,cgi-bin}
mkdir -p /etc/skel/{logs,tmp/{sessions,upload},etc,ssl/{certs,keys},backups,mail}
mkdir -p /etc/skel/.ssh

cat > /etc/skel/public_html/index.html <<'SKEL'
<!DOCTYPE html>
<html><head><title>Hosting Active</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;
height:100vh;margin:0;background:#0f172a;color:#e2e8f0}.box{text-align:center}
.emoji{font-size:4rem}.h1{font-size:2rem;margin:.5rem 0}.sub{color:#94a3b8}</style>
</head><body><div class="box"><div class="emoji">🌐</div>
<h1 class="h1">Hosting Active</h1>
<p class="sub">Upload files to <code>public_html/</code> via FTP or SFTP</p>
</div></body></html>
SKEL

cat > /etc/skel/public_html/.htaccess <<'SKEL'
Options -Indexes
DirectoryIndex index.php index.html index.htm
<FilesMatch "(^\.htaccess|\.htpasswd|\.env|\.git|wp-config\.php\.bak)$">
    Require all denied
</FilesMatch>
SKEL

cat > /etc/skel/etc/php.ini <<'SKEL'
; Per-user PHP overrides
; memory_limit = 256M
; upload_max_filesize = 64M
; max_execution_time = 120
SKEL

chmod 711  /etc/skel
chmod 755  /etc/skel/public_html
chmod 644  /etc/skel/public_html/.htaccess /etc/skel/public_html/index.html
chmod 700  /etc/skel/.ssh
chmod 750  /etc/skel/logs /etc/skel/tmp /etc/skel/etc
chmod 700  /etc/skel/ssl /etc/skel/backups
log "/etc/skel configured"

# ── 15. Logrotate ─────────────────────────────────────────────────────────────
hdr "15 · Logrotate"
cat > /etc/logrotate.d/webpanel-hosting <<'LOGROTATE'
/home/*/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    su root root
    postrotate
        systemctl reload apache2 > /dev/null 2>&1 || true
    endscript
}
LOGROTATE
log "Logrotate configured"

# ── 16. UFW ───────────────────────────────────────────────────────────────────
hdr "16 · UFW Firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh       comment 'SSH + SFTP'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'
ufw allow 8083/tcp  comment 'WebPanel-Admin'
ufw allow 8084/tcp  comment 'WebPanel-User'
ufw allow 20,21/tcp comment 'FTP'
ufw allow 40000:50000/tcp comment 'FTP-Passive'
ufw --force enable
log "UFW configured"

# ── 17. Fail2Ban ──────────────────────────────────────────────────────────────
hdr "17 · Fail2Ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled = true

[vsftpd]
enabled = true
EOF
systemctl enable fail2ban && systemctl restart fail2ban
log "Fail2Ban ready"

# ── Save credentials ──────────────────────────────────────────────────────────
cat > "$CRED_FILE" <<EOF
# ══════════════════════════════════════════
#  LAMP Server Credentials — $(date)
# ══════════════════════════════════════════
MySQL_ROOT_PASS=${MYSQL_ROOT_PASS}
PHP_VER=${PHP_VER}
TZ=${TZ}
EOF
chmod 600 "$CRED_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "LAMP Installation Complete"
echo ""
for svc in apache2 mariadb "php${PHP_VER}-fpm" redis-server fail2ban vsftpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "  ${G}✔${N} $svc — active"
    else
        echo -e "  ${R}✘${N} $svc — NOT running"
    fi
done
echo ""
echo -e "  ${Y}MySQL root password: ${MYSQL_ROOT_PASS}${N}"
echo -e "  Credentials saved : ${CRED_FILE}"
echo -e "  Run next          : ${Y}sudo bash 02_install_webpanel.sh${N}"
echo ""
