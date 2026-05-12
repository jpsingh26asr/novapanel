#!/bin/bash
# =============================================================================
#  02_install_webpanel.sh  —  WebPanel v3.0
#  cPanel-style multi-user hosting control panel for Ubuntu 22.04 / 24.04
#
#  Every hosting account = one real Linux system user
#    /home/{user}/public_html/       ← web root (primary domain)
#    /home/{user}/public_html/addons/← addon domain roots
#    /home/{user}/public_html/subdomains/ ← subdomain roots
#    /home/{user}/logs/              ← Apache per-domain logs
#    /home/{user}/tmp/               ← PHP sessions / uploads
#    /home/{user}/etc/php.ini        ← per-user PHP overrides
#    /home/{user}/.ssh/              ← SSH / SFTP keys
#    /home/{user}/backups/           ← backup tarballs
#
#  ADMIN PANEL  → :8083  (manage accounts, server, services)
#  USER PANEL   → :8084  (per-user: domains, files, DBs, cron, SSL)
#
#  Run AFTER 01_install_lamp_server.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
log()  { echo -e "${G}[✔]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[✘]${N} $*"; exit 1; }
hdr()  { echo -e "\n${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"; }

[[ $EUID -ne 0 ]] && die "Run as root:  sudo bash $0"

# ── Detect installed PHP version from FPM socket ──────────────────────────────
# This is the KEY fix: detect real PHP version, never assume 8.4
detect_php_ver() {
    # 1. Try credentials file first
    local v
    v=$(grep "^PHP_VER=" /root/.server_credentials 2>/dev/null | cut -d= -f2 | xargs)
    [[ -n "$v" ]] && { echo "$v"; return; }
    # 2. Ask php binary
    v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
    [[ -n "$v" ]] && { echo "$v"; return; }
    # 3. Scan installed FPM packages
    v=$(dpkg -l 'php*-fpm' 2>/dev/null | grep '^ii' | grep -oP '\d+\.\d+' | head -1)
    [[ -n "$v" ]] && { echo "$v"; return; }
    echo "8.3"
}

PHP_VER="$(detect_php_ver)"
PANEL_DIR="/opt/webpanel"
ADMIN_PORT="8083"
USER_PORT="8084"
ADMIN_USER="admin"
ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 18)"
PANEL_SECRET="$(openssl rand -hex 32)"
CRED_FILE="/root/.server_credentials"
LOG_FILE="/var/log/webpanel_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Read MySQL root password
MYSQL_ROOT_PASS=""
if [[ -f "$CRED_FILE" ]]; then
    MYSQL_ROOT_PASS=$(grep "^MySQL_ROOT_PASS=" "$CRED_FILE" 2>/dev/null | cut -d= -f2- | xargs)
fi
if [[ -z "$MYSQL_ROOT_PASS" ]]; then
    read -rsp "MySQL root password: " MYSQL_ROOT_PASS; echo
fi
[[ -z "$MYSQL_ROOT_PASS" ]] && die "MySQL root password is required"

hdr "WebPanel v3.0 — PHP ${PHP_VER}"
log "PHP version detected: ${PHP_VER}"
log "FPM socket will be: /run/php/php${PHP_VER}-fpm.sock"

# =============================================================================
# STEP 1 — Panel Database
# =============================================================================
hdr "Step 1 · Panel Database"
PANEL_DB="webpanel"
PANEL_DB_USER="webpanel_db"
PANEL_DB_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)"

# Use temp my.cnf — never put password on command line
DB_CNF="$(mktemp /tmp/wp_mycnf_XXXXXX)"
chmod 600 "$DB_CNF"
cat > "$DB_CNF" <<MYCNF
[client]
user=root
password=${MYSQL_ROOT_PASS}
MYCNF

mysql --defaults-extra-file="$DB_CNF" <<SQL
CREATE DATABASE IF NOT EXISTS \`${PANEL_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PANEL_DB_USER}'@'localhost' IDENTIFIED BY '${PANEL_DB_PASS}';
ALTER USER '${PANEL_DB_USER}'@'localhost' IDENTIFIED BY '${PANEL_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PANEL_DB}\`.* TO '${PANEL_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
rm -f "$DB_CNF"
log "Panel database created: ${PANEL_DB}"

# =============================================================================
# STEP 2 — Directory structure
# =============================================================================
hdr "Step 2 · Directory Structure"
mkdir -p "${PANEL_DIR}"/{admin/public,user/public,shared/{lib,config},storage/{sessions,logs},backups}
chmod 750 "${PANEL_DIR}"
log "Panel dir: ${PANEL_DIR}"

# =============================================================================
# STEP 3 — Shared Configuration
# =============================================================================
hdr "Step 3 · Shared Configuration"

# FPM socket path — hardcoded from detected version, no variables at runtime
FPM_SOCK_PATH="/run/php/php${PHP_VER}-fpm.sock"

cat > "${PANEL_DIR}/shared/config/config.php" <<PHPEOF
<?php
define('WP_VERSION',    '3.0.0');
define('PHP_VER',       '${PHP_VER}');
define('PANEL_DIR',     '${PANEL_DIR}');
define('PANEL_SECRET',  '${PANEL_SECRET}');
define('MYSQL_ROOT',    '${MYSQL_ROOT_PASS}');
define('DB_HOST',       'localhost');
define('DB_NAME',       '${PANEL_DB}');
define('DB_USER',       '${PANEL_DB_USER}');
define('DB_PASS',       '${PANEL_DB_PASS}');
define('APACHE_SITES',   '/etc/apache2/sites-available');
define('APACHE_ENABLED', '/etc/apache2/sites-enabled');
define('PHP_FPM_POOLS',  '/etc/php/${PHP_VER}/fpm/pool.d');
define('PHP_FPM_SOCK',   '/run/php');
define('FPM_SOCK_PATH',  '${FPM_SOCK_PATH}');
define('PMA_DIR',        '/opt/phpmyadmin');
define('SESSION_DIR',    '${PANEL_DIR}/storage/sessions');
define('SESSION_LIFE',   7200);
define('ADMIN_PORT',     '${ADMIN_PORT}');
define('USER_PORT',      '${USER_PORT}');
define('PANEL_GROUP',    'webpanel-users');
define('FTP_USERLIST',   '/etc/vsftpd.userlist');
define('HOSTNAME',       gethostname());
PHPEOF
log "Config written (PHP_VER=${PHP_VER})"

hdr "Step 4 · PHP Libraries"

# ── 4a. Database class ───────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/DB.php" <<'PHPEOF'
<?php
/**
 * DB — PDO wrapper for panel DB + MySQL root connection
 */
class DB {
    private static ?PDO $panel = null;
    private static ?PDO $root  = null;

    public static function panel(): PDO {
        if (!self::$panel) {
            self::$panel = new PDO(
                sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', DB_HOST, DB_NAME),
                DB_USER, DB_PASS,
                [
                    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                    PDO::ATTR_EMULATE_PREPARES   => false,
                ]
            );
        }
        return self::$panel;
    }

    public static function root(): PDO {
        if (!self::$root) {
            self::$root = new PDO(
                sprintf('mysql:host=%s;charset=utf8mb4', DB_HOST),
                'root', MYSQL_ROOT,
                [
                    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                ]
            );
        }
        return self::$root;
    }

    /** Initialize schema — idempotent */
    public static function init(): void {
        $pdo = self::panel();
        $pdo->exec("
        CREATE TABLE IF NOT EXISTS panel_users (
            id             INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            username       VARCHAR(32) UNIQUE NOT NULL,
            password_hash  VARCHAR(255) NOT NULL,
            email          VARCHAR(255) DEFAULT '',
            full_name      VARCHAR(255) DEFAULT '',
            role           ENUM('admin','user') DEFAULT 'user',
            status         ENUM('active','suspended') DEFAULT 'active',
            disk_quota_mb  INT UNSIGNED DEFAULT 5120,
            disk_used_mb   INT UNSIGNED DEFAULT 0,
            primary_domain VARCHAR(255) DEFAULT '',
            shell          VARCHAR(120) DEFAULT '/usr/sbin/nologin',
            inode_quota    INT UNSIGNED DEFAULT 100000,
            notes          TEXT,
            created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS user_domains (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NOT NULL,
            username     VARCHAR(32) NOT NULL,
            domain       VARCHAR(255) UNIQUE NOT NULL,
            type         ENUM('main','addon','subdomain','parked') DEFAULT 'main',
            webroot      VARCHAR(600) NOT NULL,
            php_version  VARCHAR(10) DEFAULT '8.4',
            ssl_enabled  TINYINT(1) DEFAULT 0,
            ssl_expiry   DATE NULL,
            redirect_https TINYINT(1) DEFAULT 0,
            status       ENUM('active','disabled') DEFAULT 'active',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES panel_users(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS user_databases (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NOT NULL,
            username     VARCHAR(32) NOT NULL,
            db_name      VARCHAR(100) UNIQUE NOT NULL,
            db_user      VARCHAR(100) UNIQUE NOT NULL,
            db_pass_enc  VARCHAR(600) NOT NULL,
            notes        VARCHAR(255) DEFAULT '',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES panel_users(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS cron_jobs (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NOT NULL,
            username     VARCHAR(32) NOT NULL,
            schedule     VARCHAR(120) NOT NULL,
            command      TEXT NOT NULL,
            enabled      TINYINT(1) DEFAULT 1,
            label        VARCHAR(255) DEFAULT '',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES panel_users(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS ssl_certs (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            domain_id    INT UNSIGNED NOT NULL,
            domain       VARCHAR(255) NOT NULL,
            issued_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            expires_at   DATE NULL,
            auto_renew   TINYINT(1) DEFAULT 1,
            FOREIGN KEY (domain_id) REFERENCES user_domains(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS activity_log (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NULL,
            username     VARCHAR(32) DEFAULT '',
            action       VARCHAR(120) DEFAULT '',
            detail       TEXT,
            ip           VARCHAR(45) DEFAULT '',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS backups (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NOT NULL,
            username     VARCHAR(32) NOT NULL,
            filename     VARCHAR(300) NOT NULL,
            size_mb      INT UNSIGNED DEFAULT 0,
            type         ENUM('full','files','db') DEFAULT 'full',
            status       ENUM('running','done','failed') DEFAULT 'running',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES panel_users(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS email_accounts (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NOT NULL,
            username     VARCHAR(32) NOT NULL,
            email        VARCHAR(255) UNIQUE NOT NULL,
            mail_user    VARCHAR(100) NOT NULL,
            domain       VARCHAR(255) NOT NULL,
            quota_mb     INT UNSIGNED DEFAULT 500,
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES panel_users(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS redirect_rules (
            id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            user_id      INT UNSIGNED NOT NULL,
            username     VARCHAR(32) NOT NULL,
            domain_id    INT UNSIGNED NOT NULL,
            src_path     VARCHAR(300) DEFAULT '/',
            dst_url      VARCHAR(600) NOT NULL,
            type         ENUM('301','302') DEFAULT '301',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES panel_users(id) ON DELETE CASCADE,
            FOREIGN KEY (domain_id) REFERENCES user_domains(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ");
    }

    /** Query returning all rows */
    public static function q(string $sql, array $p = []): array {
        $st = self::panel()->prepare($sql);
        $st->execute($p);
        return $st->fetchAll();
    }

    /** Query returning first row or null */
    public static function one(string $sql, array $p = []): ?array {
        $rows = self::q($sql, $p);
        return $rows[0] ?? null;
    }

    /** Execute DML, returns lastInsertId */
    public static function exec(string $sql, array $p = []): int {
        $st = self::panel()->prepare($sql);
        $st->execute($p);
        return (int) self::panel()->lastInsertId();
    }
}
PHPEOF

# ── 4b. Auth class ───────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/Auth.php" <<'PHPEOF'
<?php
/**
 * Auth — session management, login, role enforcement
 */
class Auth {
    public static function start(): void {
        if (session_status() !== PHP_SESSION_NONE) return;
        session_save_path(SESSION_DIR);
        ini_set('session.cookie_httponly', '1');
        ini_set('session.use_strict_mode', '1');
        ini_set('session.gc_maxlifetime',  (string) SESSION_LIFE);
        session_set_cookie_params([
            'lifetime' => SESSION_LIFE,
            'path'     => '/',
            'samesite' => 'Strict',
            'httponly' => true,
        ]);
        session_start();
    }

    public static function login(string $username, string $password, string $requiredRole = 'user'): bool {
        $username = preg_replace('/[^a-z0-9_]/', '', strtolower(trim($username)));
        $row = DB::one("SELECT * FROM panel_users WHERE username = ? AND status = 'active'", [$username]);
        if (!$row) return false;
        if (!password_verify($password, $row['password_hash'])) return false;
        if ($requiredRole === 'admin' && $row['role'] !== 'admin') return false;

        $_SESSION['uid']  = $row['id'];
        $_SESSION['user'] = $row['username'];
        $_SESSION['role'] = $row['role'];
        $_SESSION['ts']   = time();
        unset($_SESSION['su_admin']);

        self::log('login', 'role=' . $row['role']);
        return true;
    }

    /**
     * Enforce authentication. Redirects to login if session invalid or expired.
     * @param string $role  'user' (any logged-in) or 'admin'
     */
    public static function check(string $role = 'user'): void {
        self::start();
        $valid = !empty($_SESSION['user'])
            && (time() - ($_SESSION['ts'] ?? 0)) < SESSION_LIFE;

        if (!$valid) {
            session_destroy();
            header('Location: /?page=login'); exit;
        }
        if ($role === 'admin' && ($_SESSION['role'] ?? '') !== 'admin') {
            header('Location: /?page=login&err=forbidden'); exit;
        }
        // Slide session
        $_SESSION['ts'] = time();
    }

    public static function logout(): void {
        self::start();
        session_destroy();
        header('Location: /?page=login'); exit;
    }

    public static function uid(): int    { return (int)   ($_SESSION['uid']  ?? 0); }
    public static function user(): string { return (string)($_SESSION['user'] ?? ''); }
    public static function role(): string { return (string)($_SESSION['role'] ?? ''); }
    public static function isAdmin(): bool { return self::role() === 'admin'; }

    public static function log(string $action, string $detail = ''): void {
        try {
            DB::exec(
                "INSERT INTO activity_log (user_id, username, action, detail, ip) VALUES (?,?,?,?,?)",
                [self::uid(), self::user(), $action, $detail, $_SERVER['REMOTE_ADDR'] ?? '']
            );
        } catch (Exception $e) { /* non-fatal */ }
    }
}
PHPEOF

# ── 4c. SysUser — Linux system user management ──────────────────────────────
cat > "${PANEL_DIR}/shared/lib/SysUser.php" <<'PHPEOF'
<?php
/**
 * SysUser — Manages Linux system users for hosting accounts.
 *
 * Each hosting account IS a real Linux system user — identical to how
 * cPanel, DirectAdmin, and HestiaCP work.
 *
 * Directory layout created per account (cPanel-equivalent):
 *   /home/{user}/                   ← home (711, owned user:user)
 *     public_html/                  ← PRIMARY web root (755)
 *     public_html/subdomains/{name}/← subdomain webroots
 *     public_html/addons/{domain}/  ← addon domain webroots
 *     public_html/cgi-bin/          ← CGI scripts
 *     www -> public_html            ← symlink alias (like cPanel)
 *     logs/                         ← Apache per-domain access+error logs
 *     logs/archive/                 ← rotated log archive
 *     tmp/sessions/                 ← PHP session files
 *     tmp/upload/                   ← PHP upload temp
 *     etc/php.ini                   ← user-controlled PHP overrides
 *     .ssh/authorized_keys          ← SSH/SFTP keys (700)
 *     ssl/certs/ ssl/keys/          ← manual SSL cert storage
 *     backups/                      ← full backup tarballs
 *     mail/                         ← mail spool
 *
 * Security model:
 *   • PHP: per-user FPM pool, open_basedir=/home/{user}/ (process isolation)
 *   • Apache: www-data traverses home via POSIX ACL (setfacl x on home dir)
 *   • FTP: vsftpd chroot_local_user=YES → cannot escape /home/{user}/
 *   • SFTP: OpenSSH Match Group sftp-users, ChrootDirectory /home/%u
 *   • SSH: /usr/sbin/nologin by default; /bin/bash only if explicitly enabled
 */
class SysUser {
    public const GROUP      = PANEL_GROUP;       // webpanel-users
    public const SFTP_GROUP = 'sftp-users';      // SFTP chroot group (sshd)

    // ── Helpers ──────────────────────────────────────────────────────────────
    private static function sudo(string $cmd): array {
        $out = []; $rc = 0;
        exec("sudo $cmd 2>&1", $out, $rc);
        return ['rc' => $rc, 'out' => implode("\n", $out)];
    }

    private static function ensureGroups(): void {
        foreach ([self::GROUP, self::SFTP_GROUP] as $g) {
            exec("getent group $g > /dev/null 2>&1", $o, $rc);
            if ($rc !== 0) self::sudo("groupadd $g");
        }
    }

    // ── Validate username ────────────────────────────────────────────────────
    public static function validateUsername(string $u): ?string {
        if (!preg_match('/^[a-z][a-z0-9_]{2,31}$/', $u))
            return 'Username: 3-32 chars, start with letter, lowercase a-z 0-9 _ only';
        $reserved = [
            'root','admin','nobody','www-data','daemon','ftp','mail',
            'ubuntu','debian','bin','sys','sync','games','man','lp','news',
            'uucp','proxy','backup','list','irc','gnats','sshd','postfix',
            'mysql','redis','webpanel','sftp-users','webpanel-users',
        ];
        if (in_array($u, $reserved)) return "Reserved username: $u";
        return null;
    }

    // ── Create system user + full cPanel-style home structure ────────────────
    /**
     * Creates a real Linux user with all hosting directories.
     *
     * Steps:
     *  1. useradd -m  →  copies /etc/skel into /home/{user}/ automatically
     *  2. chpasswd    →  set system password (used for FTP/SSH/SFTP)
     *  3. mkdir       →  any dirs not covered by skel
     *  4. ACL         →  setfacl --execute on home so Apache can serve files
     *  5. FTP/SFTP    →  add to vsftpd userlist + sftp-users group
     *  6. Permissions →  harden per cPanel spec
     */
    public static function create(string $username, string $password, bool $shell = false): array {
        self::ensureGroups();

        if ($err = self::validateUsername($username))
            return ['ok' => false, 'msg' => $err];

        if (posix_getpwnam($username))
            return ['ok' => false, 'msg' => "System user '$username' already exists"];

        $home = "/home/$username";
        // Shell users: /bin/bash (SSH enabled). Default: nologin (FTP/SFTP only)
        $sh   = $shell ? '/bin/bash' : '/usr/sbin/nologin';

        // ── 1. Create Linux user + home dir ──────────────────────────────────
        // -m copies /etc/skel into /home/{user}/ automatically
        // -G adds to webpanel-users group (shared group for panel membership)
        // sftp-users group added separately (only for nologin SFTP users)
        $r = self::sudo("useradd -m -d $home -s $sh -G " . self::GROUP . " $username");
        if ($r['rc'] !== 0)
            return ['ok' => false, 'msg' => "useradd failed: " . $r['out']];

        // Add to sftp-users group only when no shell (SFTP chroot applies)
        if (!$shell)
            self::sudo("usermod -aG " . self::SFTP_GROUP . " $username");

        // ── 2. Set system password (FTP + SFTP + SSH) ────────────────────────
        // Use temp file to avoid all shell-quoting / injection issues
        $entry = $username . ':' . $password;
        $tmp   = tempnam('/tmp', 'wp_pw_');
        file_put_contents($tmp, $entry);
        self::sudo("bash -c \"cat $tmp | chpasswd\"");
        @unlink($tmp);

        // ── 3. Ensure all dirs exist (skel handles most; belt-and-suspenders) ─
        $dirs = [
            "$home/public_html",
            "$home/public_html/subdomains",
            "$home/public_html/addons",
            "$home/public_html/cgi-bin",
            "$home/logs",
            "$home/logs/archive",
            "$home/tmp",
            "$home/tmp/sessions",
            "$home/tmp/upload",
            "$home/etc",
            "$home/.ssh",
            "$home/ssl",
            "$home/ssl/certs",
            "$home/ssl/keys",
            "$home/backups",
            "$home/mail",
        ];
        foreach ($dirs as $d)
            self::sudo("mkdir -p " . escapeshellarg($d));

        // www → public_html alias symlink (exactly like cPanel)
        self::sudo("ln -sfn $home/public_html $home/www");

        // Write default files only if skel didn't already create them
        if (!file_exists("$home/public_html/index.html")) {
            $idx = "<html><head><title>$username's Site</title><style>"
                . "body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;"
                . "height:100vh;margin:0;background:#0f172a;color:#e2e8f0}"
                . ".box{text-align:center}.emoji{font-size:4rem}"
                . ".h1{font-size:2rem;margin:.5rem 0}.sub{color:#94a3b8}</style></head><body>"
                . "<div class='box'><div class='emoji'>🌐</div>"
                . "<h1 class='h1'>Hosting Active</h1>"
                . "<p class='sub'>Upload files to <code>public_html/</code> via FTP or SFTP</p>"
                . "<p class='sub' style='margin-top:1rem;font-size:.8rem;color:#475569'>Account: $username</p>"
                . "</div></body></html>";
            $tmp = tempnam('/tmp', 'wp_idx_');
            file_put_contents($tmp, $idx);
            self::sudo("mv $tmp $home/public_html/index.html");
        }
        if (!file_exists("$home/etc/php.ini")) {
            $phpIni = "; Per-user PHP overrides for $username\n"
                . "; memory_limit = 256M\n"
                . "; upload_max_filesize = 64M\n"
                . "; post_max_size = 64M\n"
                . "; max_execution_time = 120\n"
                . "; date.timezone = UTC\n";
            $tmp = tempnam('/tmp', 'wp_ini_');
            file_put_contents($tmp, $phpIni);
            self::sudo("mv $tmp $home/etc/php.ini");
        }

        // .ssh/authorized_keys placeholder
        if (!file_exists("$home/.ssh/authorized_keys"))
            self::sudo("touch $home/.ssh/authorized_keys");

        // ── 4. Ownership + Permissions (cPanel-spec) ─────────────────────────
        self::sudo("chown -R $username:$username $home");

        // Home dir: 711 — user can read, others can traverse (not list)
        // This is required for Apache to serve files from ~/public_html/
        // Apache gets execute (traverse) via POSIX ACL (step 5), NOT by being
        // in the user's group — this is the cleanest security model
        self::sudo("chmod 711 $home");
        self::sudo("chmod 755 $home/public_html");
        self::sudo("chmod 755 $home/public_html/subdomains");
        self::sudo("chmod 755 $home/public_html/addons");
        self::sudo("chmod 750 $home/public_html/cgi-bin");
        self::sudo("chmod 700 $home/.ssh");
        self::sudo("chmod 600 $home/.ssh/authorized_keys");
        self::sudo("chmod 750 $home/logs");
        self::sudo("chmod 750 $home/logs/archive");
        self::sudo("chmod 750 $home/tmp");
        self::sudo("chmod 750 $home/tmp/sessions");
        self::sudo("chmod 750 $home/tmp/upload");
        self::sudo("chmod 750 $home/etc");
        self::sudo("chmod 700 $home/ssl");
        self::sudo("chmod 700 $home/ssl/certs");
        self::sudo("chmod 700 $home/ssl/keys");
        self::sudo("chmod 700 $home/backups");
        if (file_exists("$home/public_html/.htaccess"))
            self::sudo("chmod 644 $home/public_html/.htaccess");
        if (file_exists("$home/public_html/robots.txt"))
            self::sudo("chmod 644 $home/public_html/robots.txt");
        if (file_exists("$home/public_html/index.html"))
            self::sudo("chmod 644 $home/public_html/index.html");
        if (file_exists("$home/etc/php.ini"))
            self::sudo("chmod 644 $home/etc/php.ini");

        // ── 5. POSIX ACL — Grant www-data traverse on home dir ───────────────
        // Problem: Apache (www-data) needs to enter /home/{user}/ to reach
        //          /home/{user}/public_html/ but home is 711 (not 755).
        //          711 means only the owner can LIST — but anyone can TRAVERSE
        //          if they know the path. However for Apache's mod_proxy_fcgi
        //          and static file serving, we need explicit execute ACL.
        //
        // Solution: setfacl grants www-data execute (x) on the home dir only.
        //   This is EXACTLY what cPanel, Plesk, and HestiaCP do.
        //   The user's files in public_html remain protected from other users.
        //
        // setfacl -m u:www-data:x /home/{user}    ← traverse only (not list)
        // setfacl -m u:www-data:rx /home/{user}/logs  ← read+traverse logs
        self::sudo("setfacl -m u:www-data:x $home");
        self::sudo("setfacl -m u:www-data:rx $home/logs");
        self::sudo("setfacl -m u:www-data:rx $home/logs/archive");
        // public_html is 755 so already world-readable — no ACL needed there

        // ── 6. FTP whitelist + SFTP group ────────────────────────────────────
        self::updateFtpList($username, true);

        return ['ok' => true, 'msg' => "Account '$username' created", 'home' => $home];
    }

    // ── Set system password (panel + FTP + SSH/SFTP all use same password) ──
    public static function setPassword(string $username, string $password): bool {
        $entry = $username . ':' . $password;
        $tmp   = tempnam('/tmp', 'wp_pw_');
        file_put_contents($tmp, $entry);
        $r = self::sudo("bash -c \"cat $tmp | chpasswd\"");
        @unlink($tmp);
        return $r['rc'] === 0;
    }

    // ── Suspend — lock all access: SSH, FTP, SFTP, disable sites ────────────
    public static function suspend(string $username): void {
        self::sudo("usermod -L $username");                   // lock password hash (FTP/SSH)
        self::sudo("usermod -s /usr/sbin/nologin $username"); // block shell
        self::updateFtpList($username, false);                // remove from FTP whitelist
    }

    // ── Unsuspend ────────────────────────────────────────────────────────────
    public static function unsuspend(string $username): void {
        self::sudo("usermod -U $username");                   // unlock password
        self::updateFtpList($username, true);
    }

    // ── Full delete — remove user, home dir, crontab, FTP entry ─────────────
    public static function delete(string $username): array {
        self::sudo("crontab -r -u $username 2>/dev/null || true");
        self::updateFtpList($username, false);
        // userdel -r removes home dir + mail spool
        $r = self::sudo("userdel -r $username 2>&1 || true");
        return ['ok' => true, 'msg' => "Account '$username' deleted"];
    }

    // ── Enable shell (SSH) ───────────────────────────────────────────────────
    public static function enableShell(string $username): bool {
        // Remove from sftp-users chroot group (shell users skip the Match block)
        self::sudo("gpasswd -d $username " . self::SFTP_GROUP . " 2>/dev/null || true");
        $r = self::sudo("usermod -s /bin/bash $username");
        return $r['rc'] === 0;
    }

    // ── Disable shell (SFTP only) ─────────────────────────────────────────
    public static function disableShell(string $username): bool {
        self::sudo("usermod -aG " . self::SFTP_GROUP . " $username");
        $r = self::sudo("usermod -s /usr/sbin/nologin $username");
        return $r['rc'] === 0;
    }

    // ── Add SSH public key ───────────────────────────────────────────────────
    public static function addSshKey(string $username, string $pubKey): array {
        $pubKey = trim($pubKey);
        if (!preg_match('/^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519) /', $pubKey))
            return ['ok' => false, 'msg' => 'Invalid SSH public key format'];
        $akFile   = "/home/$username/.ssh/authorized_keys";
        $existing = is_readable($akFile) ? file_get_contents($akFile) : '';
        if (str_contains($existing, $pubKey))
            return ['ok' => false, 'msg' => 'Key already added'];
        $tmp = tempnam('/tmp', 'wp_key_');
        file_put_contents($tmp, trim($existing) . "\n" . $pubKey . "\n");
        self::sudo("mv $tmp $akFile");
        self::sudo("chown $username:$username $akFile");
        self::sudo("chmod 600 $akFile");
        return ['ok' => true, 'msg' => 'SSH key added'];
    }

    // ── Disk usage (MB) ──────────────────────────────────────────────────────
    public static function diskUsage(string $username): int {
        $home = "/home/$username";
        if (!is_dir($home)) return 0;
        $out = [];
        exec("sudo du -sm " . escapeshellarg($home) . " 2>/dev/null | awk '{print $1}'", $out);
        return (int)($out[0] ?? 0);
    }

    // ── Fix ACL on existing account (run after re-enabling) ─────────────────
    public static function fixAcl(string $username): void {
        $home = "/home/$username";
        self::sudo("setfacl -m u:www-data:x $home");
        self::sudo("setfacl -m u:www-data:rx $home/logs");
    }

    public static function exists(string $username): bool {
        return (bool) posix_getpwnam($username);
    }

    // ── FTP whitelist helper ─────────────────────────────────────────────────
    private static function updateFtpList(string $username, bool $add): void {
        $list = file_exists(FTP_USERLIST)
            ? file(FTP_USERLIST, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : [];
        $list = array_values(array_filter($list, fn($u) => $u !== $username));
        if ($add) $list[] = $username;
        file_put_contents(FTP_USERLIST, implode("\n", $list) . "\n");
    }
}
PHPEOF

# ── 4d. VHost — Apache vhost + PHP-FPM pool management ─────────────────────
cat > "${PANEL_DIR}/shared/lib/VHost.php" <<'PHPEOF'
<?php
/**
 * VHost — Apache virtual host + per-user PHP-FPM pool management.
 *
 * Architecture (like cPanel's EasyApache):
 *   Each user gets ONE PHP-FPM pool → /run/php/php{ver}-fpm-{user}.sock
 *   ALL that user's domains use the same pool (same process isolation)
 *   Apache proxies PHP to that socket via mod_proxy_fcgi
 *   open_basedir restricts user PHP to /home/{user}/ only
 */
class VHost {

    // ── Create vHost + ensure FPM pool exists ────────────────────────────────
    public static function create(
        string $username,
        string $domain,
        string $webroot,
        string $phpVer = '8.4',
        string $type   = 'main'
    ): array {
        $domain = strtolower(trim($domain));
        if (!preg_match('/^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/', $domain))
            return ['ok' => false, 'msg' => "Invalid domain name: $domain"];

        if (file_exists(APACHE_SITES . "/$domain.conf"))
            return ['ok' => false, 'msg' => "vHost for $domain already exists"];

        // Ensure webroot exists with correct ownership
        if (!is_dir($webroot)) {
            exec("sudo mkdir -p " . escapeshellarg($webroot));
            exec("sudo chown $username:$username " . escapeshellarg($webroot));
            exec("sudo chmod 755 " . escapeshellarg($webroot));
        }

        // Create per-user FPM pool and wait for socket to appear
        self::ensureFpmPool($username, $phpVer);

        // Wait up to 10 seconds for the FPM socket to be created
        $sock    = PHP_FPM_SOCK . "/php{$phpVer}-fpm-{$username}.sock";
        $waited  = 0;
        while (!file_exists($sock) && $waited < 10) {
            sleep(1);
            $waited++;
        }
        if (!file_exists($sock)) {
            // Socket not ready — restart FPM entirely
            exec("sudo systemctl restart php{$phpVer}-fpm 2>&1");
            sleep(3);
        }

        // Write Apache vHost config
        $logDir   = "/home/$username/logs";
        $conf     = self::buildVhostConf($domain, $webroot, $username, $sock, $logDir);
        $confFile = APACHE_SITES . "/$domain.conf";
        file_put_contents($confFile, $conf);

        // Enable site
        exec("sudo a2ensite " . escapeshellarg($domain) . " 2>&1", $out, $rc);

        // Test config — run as root via sudo, suppress permission warnings
        exec("sudo apachectl configtest 2>&1", $test, $testRc);
        $testOut = implode(' ', $test);

        // Only fail on real errors, not warnings about socket not existing yet
        $isFatal = $testRc !== 0 && !str_contains($testOut, 'Syntax OK');
        if ($isFatal) {
            exec("sudo a2dissite " . escapeshellarg($domain) . " 2>&1");
            @unlink($confFile);
            return ['ok' => false, 'msg' => 'Apache config error: ' . $testOut];
        }

        exec("sudo systemctl reload apache2 2>&1");

        // Create default index only for non-primary domains
        if ($type !== 'main' && !file_exists("$webroot/index.html")) {
            $idx = "<html><body style='font-family:sans-serif;text-align:center;padding:4rem'>"
                 . "<h2>$domain</h2><p>Upload files to this domain's webroot via FTP/SFTP</p>"
                 . "<small style='color:#999'>/home/$username/...</small></body></html>";
            $tmp = tempnam('/tmp', 'wp_');
            file_put_contents($tmp, $idx);
            exec("sudo mv $tmp $webroot/index.html");
            exec("sudo chown $username:$username $webroot/index.html");
        }

        return ['ok' => true, 'msg' => "vHost $domain created", 'conf' => $confFile];
    }

    // ── Delete vHost ─────────────────────────────────────────────────────────
    public static function delete(string $domain): void {
        exec("sudo a2dissite " . escapeshellarg($domain) . " 2>&1");
        $f = APACHE_SITES . "/$domain.conf";
        if (file_exists($f)) unlink($f);
        exec("sudo systemctl reload apache2 2>&1");
    }

    public static function enable(string $domain): void {
        exec("sudo a2ensite "  . escapeshellarg($domain) . " 2>&1");
        exec("sudo systemctl reload apache2 2>&1");
    }
    public static function disable(string $domain): void {
        exec("sudo a2dissite " . escapeshellarg($domain) . " 2>&1");
        exec("sudo systemctl reload apache2 2>&1");
    }

    // ── Per-user PHP-FPM pool ─────────────────────────────────────────────
    /**
     * Creates /etc/php/{ver}/fpm/pool.d/{username}.conf
     * Isolated: own socket, open_basedir to /home/{user}/, own error log
     */
    public static function ensureFpmPool(string $username, string $phpVer): void {
        $poolFile = PHP_FPM_POOLS . "/$username.conf";
        if (file_exists($poolFile)) return;

        $pool = <<<POOL
; WebPanel — per-user PHP-FPM pool for {$username}
; All domains belonging to {$username} use this pool (process isolation)
[{$username}]
user  = {$username}
group = {$username}

; Unix socket — Apache proxies PHP requests here via mod_proxy_fcgi
listen = /run/php/php{$phpVer}-fpm-{$username}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

; Process manager
pm                   = ondemand
pm.max_children      = 10
pm.process_idle_timeout = 30s
pm.max_requests      = 500

; Idle timeout
request_terminate_timeout = 120s

; Per-user filesystem jail (open_basedir)
php_admin_value[open_basedir]    = /home/{$username}/:/tmp/:/usr/share/php/:/usr/share/pear/
php_admin_value[upload_tmp_dir]  = /home/{$username}/tmp/upload/
php_value[session.save_path]     = /home/{$username}/tmp/sessions/
php_admin_value[error_log]       = /home/{$username}/logs/php_error.log
php_admin_flag[log_errors]       = on
php_admin_flag[display_errors]   = off

; Per-user resource limits
php_value[memory_limit]          = 256M
php_value[upload_max_filesize]   = 64M
php_value[post_max_size]         = 64M
php_value[max_execution_time]    = 120
php_value[max_input_time]        = 120

catch_workers_output = yes
decorate_workers_output = no
POOL;

        file_put_contents($poolFile, $pool);
        // Restart (not reload) so new pool socket is actually created
        exec("sudo systemctl restart php{$phpVer}-fpm 2>&1");
        // Give FPM time to start the new pool and create the socket
        sleep(2);
    }

    public static function removeFpmPool(string $username, string $phpVer): void {
        $f = PHP_FPM_POOLS . "/$username.conf";
        if (file_exists($f)) {
            unlink($f);
            exec("sudo systemctl reload php{$phpVer}-fpm 2>&1");
        }
    }

    // ── Build Apache vHost config string ────────────────────────────────────
    private static function buildVhostConf(
        string $domain, string $webroot, string $username,
        string $sock, string $logDir
    ): string {
        return <<<APACHE
# WebPanel — auto-generated for {$domain} ({$username})
# DO NOT EDIT MANUALLY — manage via WebPanel admin/user panel

<VirtualHost *:80>
    ServerName   {$domain}
    ServerAlias  www.{$domain}
    DocumentRoot {$webroot}

    # www → non-www canonical redirect (edit via panel to change direction)
    # RewriteEngine On
    # RewriteCond %{HTTP_HOST} ^www\.(.+)$ [NC]
    # RewriteRule ^ http://%1%{REQUEST_URI} [R=301,L]

    <Directory {$webroot}>
        Options -Indexes +FollowSymLinks +MultiViews
        AllowOverride All
        Require all granted

        # Block hidden files (except .well-known for Let's Encrypt)
        <FilesMatch "^\.(?!well-known)">
            Require all denied
        </FilesMatch>
    </Directory>

    # CGI scripts
    <Directory {$webroot}/../cgi-bin>
        Options +ExecCGI
        AddHandler cgi-script .cgi .pl .sh
        Require all granted
    </Directory>
    ScriptAlias /cgi-bin/ {$webroot}/../cgi-bin/

    # Route ALL PHP requests to per-user isolated FPM socket
    # This is the core security boundary — each user has their own PHP process
    <FilesMatch "\.php$">
        SetHandler "proxy:unix:{$sock}|fcgi://localhost"
    </FilesMatch>

    # Pass Authorization header to PHP (needed for REST APIs / JWT)
    SetEnvIf Authorization "(.+)" HTTP_AUTHORIZATION=\$1

    # Compression
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/css application/javascript application/json
    </IfModule>

    # Custom error pages (user can create these in their webroot)
    ErrorDocument 400 /error/400.html
    ErrorDocument 403 /error/403.html
    ErrorDocument 404 /error/404.html
    ErrorDocument 500 /error/500.html
    ErrorDocument 503 /error/503.html

    # Logs land in user home (per-domain, like cPanel)
    ErrorLog  {$logDir}/{$domain}-error.log
    CustomLog {$logDir}/{$domain}-access.log combined

    # Security headers
    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"
    </IfModule>
</VirtualHost>
APACHE;
    }

    // ── Add HTTPS redirect + SSL block (after certbot) ──────────────────────
    public static function addHttpsRedirect(string $domain): void {
        $f = APACHE_SITES . "/$domain.conf";
        if (!file_exists($f)) return;
        $conf = file_get_contents($f);
        // Already has HTTPS block?
        if (str_contains($conf, 'VirtualHost *:443')) return;
        // Change HTTP vHost to redirect only
        $conf = str_replace(
            "<VirtualHost *:80>",
            "<VirtualHost *:80>\n    Redirect permanent / https://{$domain}/",
            $conf
        );
        file_put_contents($f, $conf);
        exec("sudo systemctl reload apache2 2>&1");
    }

    public static function getStatus(string $domain): string {
        return file_exists(APACHE_ENABLED . "/$domain.conf") ? 'enabled' : 'disabled';
    }

    public static function getConf(string $domain): string {
        $f = APACHE_SITES . "/$domain.conf";
        return file_exists($f) ? file_get_contents($f) : '';
    }
}
PHPEOF

# ── 4e. SSLManager ───────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/SSLManager.php" <<'PHPEOF'
<?php
class SSLManager {
    public static function issue(string $domain, string $email): array {
        $cmd = sprintf(
            'sudo certbot --apache -d %s --non-interactive --agree-tos -m %s --redirect 2>&1',
            escapeshellarg($domain),
            escapeshellarg($email)
        );
        $out = []; $rc = 0;
        exec($cmd, $out, $rc);
        $output = implode("\n", $out);
        $ok = $rc === 0 || str_contains($output, 'Congratulations')
                        || str_contains($output, 'Certificate not yet due');
        return ['ok' => $ok, 'output' => $output];
    }

    public static function revoke(string $domain): array {
        $out = [];
        exec("sudo certbot delete --cert-name " . escapeshellarg($domain) . " --non-interactive 2>&1", $out, $rc);
        return ['ok' => $rc === 0, 'output' => implode("\n", $out)];
    }

    public static function expiry(string $domain): ?string {
        $cert = "/etc/letsencrypt/live/$domain/fullchain.pem";
        if (!file_exists($cert)) return null;
        $out = [];
        exec("openssl x509 -enddate -noout -in " . escapeshellarg($cert) . " 2>/dev/null", $out);
        if ($out && preg_match('/notAfter=(.+)$/', $out[0], $m))
            return date('Y-m-d', strtotime($m[1]));
        return null;
    }

    public static function isValid(string $domain): bool {
        return file_exists("/etc/letsencrypt/live/$domain/fullchain.pem");
    }

    public static function daysUntilExpiry(string $domain): ?int {
        $exp = self::expiry($domain);
        if (!$exp) return null;
        return max(0, (int) ceil((strtotime($exp) - time()) / 86400));
    }
}
PHPEOF

# ── 4f. DBManager ────────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/DBManager.php" <<'PHPEOF'
<?php
/**
 * DBManager — per-user MariaDB database management.
 * All DB names and users are prefixed with username_ (like cPanel).
 */
class DBManager {
    private static function safe(string $s): string {
        return preg_replace('/[^a-zA-Z0-9_]/', '', $s);
    }

    public static function createDB(
        string $username,
        string $dbSuffix,
        string $userSuffix,
        string $dbPass
    ): array {
        $dbName  = self::safe($username . '_' . $dbSuffix);
        $dbUser  = self::safe($username . '_' . $userSuffix);

        if (strlen($dbName) > 64) return ['ok' => false, 'msg' => 'Database name too long (max 64 chars)'];
        if (strlen($dbUser) > 80) return ['ok' => false, 'msg' => 'DB username too long'];
        if (strlen($dbPass) < 8)  return ['ok' => false, 'msg' => 'DB password must be at least 8 characters'];

        try {
            $pdo = DB::root();
            // Check if DB already exists
            $exists = $pdo->query("SHOW DATABASES LIKE '$dbName'")->rowCount();
            if ($exists) return ['ok' => false, 'msg' => "Database '$dbName' already exists"];

            $pdo->exec("CREATE DATABASE `$dbName` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
            $pdo->exec("CREATE USER IF NOT EXISTS '$dbUser'@'localhost' IDENTIFIED BY '$dbPass'");
            $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'localhost'");
            $pdo->exec("FLUSH PRIVILEGES");

            // Encrypt password for storage (display only)
            $iv  = substr(PANEL_SECRET, 0, 16);
            $enc = base64_encode(openssl_encrypt($dbPass, 'AES-256-CBC', PANEL_SECRET, 0, $iv));

            DB::exec(
                "INSERT INTO user_databases (user_id, username, db_name, db_user, db_pass_enc) VALUES (?,?,?,?,?)",
                [Auth::uid(), $username, $dbName, $dbUser, $enc]
            );
            Auth::log('db_create', $dbName);

            return [
                'ok'      => true,
                'msg'     => "Database created",
                'db_name' => $dbName,
                'db_user' => $dbUser,
                'db_pass' => $dbPass,
            ];
        } catch (PDOException $e) {
            return ['ok' => false, 'msg' => $e->getMessage()];
        }
    }

    public static function dropDB(int $id, string $username): array {
        $row = DB::one("SELECT * FROM user_databases WHERE id = ? AND username = ?", [$id, $username]);
        if (!$row) return ['ok' => false, 'msg' => 'Database not found'];
        try {
            $pdo = DB::root();
            $pdo->exec("DROP DATABASE IF EXISTS `{$row['db_name']}`");
            $pdo->exec("DROP USER IF EXISTS '{$row['db_user']}'@'localhost'");
            $pdo->exec("FLUSH PRIVILEGES");
            DB::exec("DELETE FROM user_databases WHERE id = ?", [$id]);
            Auth::log('db_drop', $row['db_name']);
            return ['ok' => true, 'msg' => "Dropped {$row['db_name']}"];
        } catch (PDOException $e) {
            return ['ok' => false, 'msg' => $e->getMessage()];
        }
    }

    public static function listForUser(string $username): array {
        return DB::q(
            "SELECT id, db_name, db_user, notes, created_at FROM user_databases WHERE username = ? ORDER BY created_at DESC",
            [$username]
        );
    }

    public static function listAll(): array {
        return DB::q("SELECT d.*, p.email FROM user_databases d LEFT JOIN panel_users p ON d.username = p.username ORDER BY d.created_at DESC");
    }
}
PHPEOF

# ── 4g. CronManager ──────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/CronManager.php" <<'PHPEOF'
<?php
class CronManager {
    private static function validateSchedule(string $s): bool {
        $parts = preg_split('/\s+/', trim($s));
        if (count($parts) !== 5) return false;
        $patterns = [
            '/^(\*|([0-5]?\d)(,([0-5]?\d))*|(\*\/[1-9]\d?))$/', // min
            '/^(\*|(1?\d|2[0-3])(,(1?\d|2[0-3]))*|(\*\/[1-9]\d?))$/', // hour
            '/^(\*|([12]?\d|3[01])(,([12]?\d|3[01]))*|(\*\/[1-9]\d*))$/', // dom
            '/^(\*|(1[0-2]|[1-9])(,(1[0-2]|[1-9]))*|(\*\/[1-9]\d?))$/', // mon
            '/^(\*|[0-7](,[0-7])*|(\*\/[1-7]))$/', // dow
        ];
        foreach ($parts as $i => $p)
            if (!preg_match($patterns[$i], $p)) return false;
        return true;
    }

    public static function add(int $userId, string $username, string $schedule, string $cmd, string $label = ''): array {
        if (!self::validateSchedule($schedule))
            return ['ok' => false, 'msg' => 'Invalid cron schedule. Use 5 fields: min hour day month weekday'];

        // Basic sanitization — no shell injection
        $cmd = preg_replace('/[;&|`$]/', '', $cmd);
        if (empty(trim($cmd))) return ['ok' => false, 'msg' => 'Command is required'];

        DB::exec(
            "INSERT INTO cron_jobs (user_id, username, schedule, command, label) VALUES (?,?,?,?,?)",
            [$userId, $username, $schedule, $cmd, substr($label, 0, 255)]
        );
        self::syncCrontab($username);
        Auth::log('cron_add', "$schedule $cmd");
        return ['ok' => true, 'msg' => 'Cron job added'];
    }

    public static function delete(int $id, string $username): array {
        $row = DB::one("SELECT id FROM cron_jobs WHERE id = ? AND username = ?", [$id, $username]);
        if (!$row) return ['ok' => false, 'msg' => 'Cron job not found'];
        DB::exec("DELETE FROM cron_jobs WHERE id = ?", [$id]);
        self::syncCrontab($username);
        return ['ok' => true, 'msg' => 'Deleted'];
    }

    public static function toggle(int $id, string $username): bool {
        $row = DB::one("SELECT enabled FROM cron_jobs WHERE id = ? AND username = ?", [$id, $username]);
        if (!$row) return false;
        DB::exec("UPDATE cron_jobs SET enabled = 1 - enabled WHERE id = ?", [$id]);
        self::syncCrontab($username);
        return true;
    }

    /** Rebuild system crontab for user from DB records */
    public static function syncCrontab(string $username): void {
        $jobs = DB::q(
            "SELECT * FROM cron_jobs WHERE username = ? AND enabled = 1 ORDER BY id",
            [$username]
        );
        if (empty($jobs)) {
            exec("sudo crontab -r -u $username 2>/dev/null || true");
            return;
        }
        $lines = [
            "# WebPanel managed crontab for $username",
            "# DO NOT EDIT — changes will be overwritten by WebPanel",
            'SHELL=/bin/sh',
            'PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin',
            'MAILTO=""',
        ];
        foreach ($jobs as $j) {
            $comment = $j['label'] ? "# " . $j['label'] : '';
            if ($comment) $lines[] = $comment;
            $lines[] = $j['schedule'] . ' ' . $j['command'];
        }
        $tmp = tempnam('/tmp', 'cron_');
        file_put_contents($tmp, implode("\n", $lines) . "\n");
        exec("sudo crontab -u $username $tmp 2>&1");
        unlink($tmp);
    }

    public static function listForUser(string $username): array {
        return DB::q("SELECT * FROM cron_jobs WHERE username = ? ORDER BY created_at DESC", [$username]);
    }
}
PHPEOF

# ── 4h. FileManager ──────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/FileManager.php" <<'PHPEOF'
<?php
/**
 * FileManager — safe file operations chrooted to /home/{user}/
 * Any path traversal attempt outside home throws RuntimeException.
 */
class FileManager {
    private string $base;
    private string $username;

    public function __construct(string $username) {
        $this->username = $username;
        $this->base     = "/home/$username";
    }

    /** Resolve and validate path stays within home */
    private function safe(string $path): string {
        // Normalize: prepend base, resolve real path
        $full = $this->base . '/' . ltrim($path, '/');
        // For existing paths use realpath; for new paths clean manually
        if (file_exists($full)) {
            $real = realpath($full);
            if (!$real || !str_starts_with($real, $this->base))
                throw new RuntimeException("Access denied: path outside home directory");
            return $real;
        }
        // New path — clean it
        $clean = $this->base . '/' . implode('/', array_filter(
            explode('/', $path), fn($p) => $p !== '' && $p !== '..'
        ));
        if (!str_starts_with($clean, $this->base))
            throw new RuntimeException("Access denied");
        return $clean;
    }

    public function ls(string $path = '/'): array {
        $dir = $this->safe($path);
        if (!is_dir($dir)) throw new RuntimeException("Not a directory");
        $items = [];
        $dh = opendir($dir);
        while (($f = readdir($dh)) !== false) {
            if ($f === '.') continue;
            $full = "$dir/$f";
            $isDir  = is_dir($full);
            $isLink = is_link($full);
            $items[] = [
                'name'     => $f,
                'type'     => $isDir ? 'dir' : 'file',
                'size'     => $isDir ? 0 : (int)@filesize($full),
                'perms'    => substr(sprintf('%o', @fileperms($full)), -4),
                'modified' => date('Y-m-d H:i', (int)@filemtime($full)),
                'is_link'  => $isLink,
                'link_to'  => $isLink ? @readlink($full) : null,
            ];
        }
        closedir($dh);
        usort($items, fn($a, $b) =>
            ($a['type'] === 'dir' ? 0 : 1) <=> ($b['type'] === 'dir' ? 0 : 1)
            ?: strnatcasecmp($a['name'], $b['name'])
        );
        return $items;
    }

    public function read(string $path): string {
        $f = $this->safe($path);
        if (!is_file($f)) throw new RuntimeException("Not a file");
        if (filesize($f) > 2 * 1024 * 1024) throw new RuntimeException("File too large to edit inline (>2 MB)");
        return file_get_contents($f);
    }

    public function write(string $path, string $content): void {
        $f = $this->safe($path);
        // Write to temp then move (atomic)
        $tmp = tempnam(dirname($f), '.wp_tmp_');
        file_put_contents($tmp, $content);
        rename($tmp, $f);
        $u = $this->username;
        exec("sudo chown $u:$u " . escapeshellarg($f));
    }

    public function mkdir(string $path): void {
        $full = $this->safe($path);
        if (is_dir($full)) throw new RuntimeException("Directory already exists");
        if (!mkdir($full, 0755, true))
            throw new RuntimeException("Failed to create directory");
        $u = $this->username;
        exec("sudo chown $u:$u " . escapeshellarg($full));
    }

    public function delete(string $path): void {
        $f = $this->safe($path);
        if (realpath($f) === $this->base) throw new RuntimeException("Cannot delete home directory");
        if (is_dir($f) && !is_link($f))
            exec("sudo rm -rf " . escapeshellarg($f));
        else
            unlink($f);
    }

    public function rename(string $from, string $to): void {
        $src = $this->safe($from);
        $dst = $this->safe($to);
        if (file_exists($dst)) throw new RuntimeException("Destination already exists");
        rename($src, $dst);
        $u = $this->username;
        exec("sudo chown $u:$u " . escapeshellarg($dst));
    }

    public function chmod(string $path, string $mode): void {
        if (!preg_match('/^[0-7]{3,4}$/', $mode)) throw new RuntimeException("Invalid mode");
        $f = $this->safe($path);
        chmod($f, octdec($mode));
    }

    public function upload(string $destDir, array $fileInfo): void {
        $dest = $this->safe($destDir);
        if (!is_dir($dest)) throw new RuntimeException("Destination is not a directory");
        $filename = basename($fileInfo['name']);
        if (!$filename || $filename[0] === '.') throw new RuntimeException("Invalid filename");
        $target = "$dest/$filename";
        if (!move_uploaded_file($fileInfo['tmp_name'], $target))
            throw new RuntimeException("Upload failed");
        $u = $this->username;
        exec("sudo chown $u:$u " . escapeshellarg($target));
    }

    public static function humanSize(int $bytes): string {
        foreach (['B', 'KB', 'MB', 'GB'] as $unit) {
            if ($bytes < 1024) return round($bytes, 1) . ' ' . $unit;
            $bytes = (int)($bytes / 1024);
        }
        return $bytes . ' TB';
    }

    /** Editable file types (show code editor) */
    public static function isEditable(string $name): bool {
        return (bool) preg_match('/\.(php|html?|css|js|ts|json|xml|yaml|yml|ini|conf|sh|txt|md|log|htaccess|env)$/i', $name);
    }
}
PHPEOF

# ── 4i. BackupManager ────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/shared/lib/BackupManager.php" <<'PHPEOF'
<?php
/**
 * BackupManager — creates tar.gz backups of user home + dumps their DBs
 */
class BackupManager {
    public static function runBackup(int $userId, string $username): array {
        $home       = "/home/$username";
        $backupDir  = "$home/backups";
        $ts         = date('Y-m-d_H-i-s');
        $filename   = "{$username}_backup_{$ts}.tar.gz";
        $backupPath = "$backupDir/$filename";
        $dbDumpPath = "/tmp/{$username}_dbs_{$ts}.sql";

        // Log backup as running
        $bid = DB::exec(
            "INSERT INTO backups (user_id, username, filename, type, status) VALUES (?,?,?,'full','running')",
            [$userId, $username, $filename]
        );

        // Dump all user's databases
        $dbs = DB::q("SELECT db_name, db_user FROM user_databases WHERE username = ?", [$username]);
        $dbDumps = '';
        foreach ($dbs as $db) {
            $out = [];
            exec("mysqldump -u root -p" . escapeshellarg(MYSQL_ROOT) . " --single-transaction "
                . escapeshellarg($db['db_name']) . " 2>/dev/null", $out);
            $dbDumps .= "-- Database: {$db['db_name']}\n" . implode("\n", $out) . "\n\n";
        }
        if ($dbDumps) file_put_contents($dbDumpPath, $dbDumps);

        // Create tar.gz of home dir (excluding backups dir itself)
        $excludeBackups = "--exclude=$home/backups";
        $includeDb = $dbDumps ? " $dbDumpPath" : '';
        exec("sudo tar -czf " . escapeshellarg($backupPath)
            . " $excludeBackups -C /home $username$includeDb 2>&1", $out, $rc);

        if ($dbDumps && file_exists($dbDumpPath)) @unlink($dbDumpPath);

        $sizeMb = file_exists($backupPath) ? (int)(filesize($backupPath) / 1048576) : 0;
        $status = ($rc === 0) ? 'done' : 'failed';

        exec("sudo chown $username:$username " . escapeshellarg($backupPath) . " 2>/dev/null || true");

        DB::exec("UPDATE backups SET status = ?, size_mb = ? WHERE id = ?", [$status, $sizeMb, $bid]);
        Auth::log('backup', "$filename ($sizeMb MB) $status");

        return [
            'ok'       => $rc === 0,
            'msg'      => $rc === 0 ? "Backup created: $filename ($sizeMb MB)" : "Backup failed",
            'filename' => $filename,
            'size_mb'  => $sizeMb,
        ];
    }

    public static function listBackups(string $username): array {
        return DB::q(
            "SELECT * FROM backups WHERE username = ? ORDER BY created_at DESC LIMIT 20",
            [$username]
        );
    }

    public static function deleteBackup(int $id, string $username): array {
        $row = DB::one("SELECT filename FROM backups WHERE id = ? AND username = ?", [$id, $username]);
        if (!$row) return ['ok' => false, 'msg' => 'Backup not found'];
        $path = "/home/$username/backups/{$row['filename']}";
        if (file_exists($path)) @unlink($path);
        DB::exec("DELETE FROM backups WHERE id = ?", [$id]);
        return ['ok' => true, 'msg' => 'Backup deleted'];
    }
}
PHPEOF

log "All shared PHP libraries written"

# =============================================================================
# STEP 5 — Bootstrap files (shared by admin + user panels)
# =============================================================================
hdr "Step 5 · Bootstrap Files"

write_bootstrap() {
    local dir="$1"
    cat > "${dir}/bootstrap.php" <<PHPEOF
<?php
define('PANEL_ROOT', '${PANEL_DIR}');
require_once PANEL_ROOT . '/shared/config/config.php';
// Auto-load all shared libraries
foreach (glob(PANEL_ROOT . '/shared/lib/*.php') as \$lib) require_once \$lib;
DB::init();
Auth::start();
PHPEOF
}
write_bootstrap "${PANEL_DIR}/admin/public"
write_bootstrap "${PANEL_DIR}/user/public"
log "Bootstrap files written"

# =============================================================================
# STEP 6 — Admin Panel
# =============================================================================
hdr "Step 6 · Admin Panel"

# ── Admin index (router) ─────────────────────────────────────────────────────
cat > "${PANEL_DIR}/admin/public/index.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/bootstrap.php';

$page = $_GET['page'] ?? 'dashboard';

// JSON API endpoint
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_GET['api'])) {
    Auth::check('admin');
    header('Content-Type: application/json');
    require_once __DIR__ . '/api.php';
    exit;
}

if ($page === 'logout') Auth::logout();

if ($page === 'login') {
    $err = '';
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        if (Auth::login($_POST['username'] ?? '', $_POST['password'] ?? '', 'admin')) {
            header('Location: /'); exit;
        }
        $err = 'Invalid credentials or you do not have admin access.';
    }
    include __DIR__ . '/tpl_login.php';
    exit;
}

Auth::check('admin');
include __DIR__ . '/tpl_panel.php';
PHPEOF

# ── Admin Login template ──────────────────────────────────────────────────────
cat > "${PANEL_DIR}/admin/public/tpl_login.php" <<'PHPEOF'
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WebPanel — Admin Login</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Outfit:wght@300;600;800&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#04080f;--surf:#080f1c;--brd:#0f1e36;--acc:#00c8f8;--acc2:#6e45e2;--text:#dce8ff;--muted:#4a6a90;--red:#ff4d6d}
body{background:var(--bg);min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:'Outfit',sans-serif;overflow:hidden}
.rings{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;pointer-events:none;opacity:.15}
.ring{border-radius:50%;border:1px solid var(--acc);position:absolute;animation:pulse 4s ease-in-out infinite}
.ring:nth-child(1){width:400px;height:400px;animation-delay:0s}
.ring:nth-child(2){width:600px;height:600px;animation-delay:.8s}
.ring:nth-child(3){width:800px;height:800px;animation-delay:1.6s}
@keyframes pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.05);opacity:.4}}
.glow{position:fixed;width:600px;height:600px;border-radius:50%;background:radial-gradient(circle,rgba(0,200,248,.06),transparent 70%);top:50%;left:50%;transform:translate(-50%,-50%);pointer-events:none}
.card{position:relative;background:var(--surf);border:1px solid var(--brd);border-radius:20px;padding:3rem 2.6rem;width:420px;box-shadow:0 40px 100px rgba(0,0,0,.7)}
.card::before{content:'';position:absolute;inset:-1px;border-radius:20px;background:linear-gradient(135deg,rgba(0,200,248,.12),transparent 50%);pointer-events:none;z-index:-1}
.logo{text-align:center;margin-bottom:2.5rem}
.logo-box{display:inline-flex;align-items:center;justify-content:center;width:60px;height:60px;border-radius:16px;background:linear-gradient(135deg,var(--acc),var(--acc2));margin-bottom:.9rem;font-size:1.8rem}
.logo h1{font-weight:800;font-size:1.7rem;background:linear-gradient(135deg,var(--acc),var(--acc2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:.06em}
.logo p{color:var(--muted);font-size:.7rem;font-family:'JetBrains Mono',monospace;letter-spacing:.12em;margin-top:.3rem}
.fgrp{margin-bottom:1.1rem}
.fgrp label{display:block;color:var(--muted);font-size:.65rem;text-transform:uppercase;letter-spacing:.12em;font-family:'JetBrains Mono',monospace;margin-bottom:.45rem}
.fgrp input{width:100%;background:rgba(0,200,248,.04);border:1px solid var(--brd);border-radius:10px;padding:.78rem 1.1rem;color:var(--text);font-family:'Outfit',sans-serif;font-size:.9rem;transition:.2s}
.fgrp input:focus{outline:none;border-color:var(--acc);background:rgba(0,200,248,.07);box-shadow:0 0 0 3px rgba(0,200,248,.08)}
.btn{width:100%;background:linear-gradient(135deg,var(--acc),var(--acc2));border:none;border-radius:10px;padding:.88rem;color:#04080f;font-family:'Outfit',sans-serif;font-weight:800;font-size:.95rem;cursor:pointer;letter-spacing:.05em;transition:.2s;margin-top:.4rem}
.btn:hover{opacity:.9;box-shadow:0 8px 24px rgba(0,200,248,.25);transform:translateY(-1px)}
.err{background:rgba(255,77,109,.08);border:1px solid rgba(255,77,109,.25);color:var(--red);border-radius:8px;padding:.65rem 1rem;font-size:.82rem;text-align:center;margin-bottom:1rem}
.tag{display:inline-block;background:rgba(110,69,226,.15);color:var(--acc2);border:1px solid rgba(110,69,226,.3);border-radius:20px;padding:.15rem .7rem;font-size:.6rem;font-family:'JetBrains Mono',monospace;letter-spacing:.1em;margin-top:.25rem}
</style>
</head><body>
<div class="rings"><div class="ring"></div><div class="ring"></div><div class="ring"></div></div>
<div class="glow"></div>
<div class="card">
  <div class="logo">
    <div class="logo-box">🖥</div>
    <h1>WEBPANEL</h1>
    <p>SERVER CONTROL PANEL</p>
    <span class="tag">ADMINISTRATOR ACCESS</span>
  </div>
  <?php if($err): ?><div class="err"><?=htmlspecialchars($err)?></div><?php endif; ?>
  <form method="POST">
    <div class="fgrp"><label>Username</label><input type="text" name="username" autocomplete="username" required autofocus placeholder="admin"></div>
    <div class="fgrp"><label>Password</label><input type="password" name="password" autocomplete="current-password" required placeholder="• • • • • • • •"></div>
    <button type="submit" class="btn">SIGN IN →</button>
  </form>
</div>
</body></html>
PHPEOF

# ── Admin API ─────────────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/admin/public/api.php" <<'PHPEOF'
<?php
// Admin JSON API — all POST ?api=ACTION requests land here
$action = $_GET['api'] ?? '';
$data   = json_decode(file_get_contents('php://input'), true) ?? $_POST;

function ok(string $msg, array $extra = []): void {
    echo json_encode(['ok' => true, 'msg' => $msg] + $extra);
    exit;
}
function err(string $msg, int $code = 200): void {
    http_response_code($code);
    echo json_encode(['ok' => false, 'msg' => $msg]);
    exit;
}
function int_param(string $key): int { global $data; return (int)($data[$key] ?? 0); }
function str_param(string $key): string { global $data; return (string)($data[$key] ?? ''); }

switch ($action) {

// ─── Server ──────────────────────────────────────────────────────────────────
case 'server_stats':
    $load = sys_getloadavg();
    $mem  = []; exec('free -m | grep "^Mem:"', $mem);
    $mp   = preg_split('/\s+/', trim($mem[0] ?? ''));
    $disk = []; exec("df -h / | tail -1", $disk);
    $dp   = preg_split('/\s+/', trim($disk[0] ?? ''));
    ok('ok', [
        'hostname'   => gethostname(),
        'uptime'     => trim((string)shell_exec('uptime -p')),
        'load'       => array_map(fn($v) => round((float)$v, 2), $load),
        'mem_total'  => $mp[1] ?? '?',
        'mem_used'   => $mp[2] ?? '?',
        'mem_free'   => $mp[3] ?? '?',
        'mem_pct'    => isset($mp[1],$mp[2]) && $mp[1] > 0 ? round($mp[2]/$mp[1]*100) : 0,
        'disk_size'  => $dp[1] ?? '?',
        'disk_used'  => $dp[2] ?? '?',
        'disk_avail' => $dp[3] ?? '?',
        'disk_pct'   => $dp[4] ?? '?',
        'php'        => PHP_VERSION,
        'os'         => trim((string)shell_exec('lsb_release -d | cut -f2')),
        'accounts'   => (int)DB::one("SELECT COUNT(*) c FROM panel_users WHERE role='user'")['c'],
        'domains'    => (int)DB::one("SELECT COUNT(*) c FROM user_domains")['c'],
        'dbs'        => (int)DB::one("SELECT COUNT(*) c FROM user_databases")['c'],
    ]);

case 'service_status':
    $svcs = ['apache2','mariadb','php'.PHP_VER.'-fpm','redis-server','fail2ban','vsftpd','postfix','memcached'];
    $status = [];
    foreach ($svcs as $s) {
        $out = []; exec("systemctl is-active " . escapeshellarg($s) . " 2>&1", $out);
        $status[$s] = trim($out[0] ?? 'unknown');
    }
    ok('ok', ['services' => $status]);

case 'service_action':
    $svc = preg_replace('/[^a-z0-9\-_.]/', '', str_param('service'));
    $act = str_param('action');
    $allowed_svcs = ['apache2','mariadb','php'.PHP_VER.'-fpm','redis-server','fail2ban','vsftpd','postfix','memcached'];
    $allowed_acts = ['start','stop','restart','reload','status'];
    if (!in_array($svc, $allowed_svcs)) err("Service not allowed: $svc");
    if (!in_array($act, $allowed_acts)) err("Action not allowed: $act");
    $out = []; exec("sudo systemctl $act $svc 2>&1", $out, $rc);
    ok(implode("\n", $out) ?: 'OK', ['rc' => $rc]);

// ─── Accounts ────────────────────────────────────────────────────────────────
case 'users_list':
    $users = DB::q("SELECT id, username, email, full_name, role, status, disk_quota_mb, disk_used_mb, primary_domain, created_at FROM panel_users ORDER BY created_at DESC");
    foreach ($users as &$u) {
        $u['disk_used_mb'] = SysUser::diskUsage($u['username']);
        DB::exec("UPDATE panel_users SET disk_used_mb = ? WHERE id = ?", [$u['disk_used_mb'], $u['id']]);
        $u['domain_count'] = (int)DB::one("SELECT COUNT(*) c FROM user_domains WHERE username=?",[$u['username']])['c'];
        $u['db_count']     = (int)DB::one("SELECT COUNT(*) c FROM user_databases WHERE username=?",[$u['username']])['c'];
    }
    ok('ok', ['users' => $users]);

case 'user_create':
    $u     = preg_replace('/[^a-z0-9_]/', '', strtolower(str_param('username')));
    $p     = str_param('password');
    $email = filter_var(str_param('email'), FILTER_VALIDATE_EMAIL) ?: '';
    $fname = htmlspecialchars(str_param('full_name'));
    $quota = max(256, min(102400, int_param('quota_mb') ?: 5120));
    $shell = !empty($data['shell_access']) && $data['shell_access'] !== '0' && $data['shell_access'] !== '';
    $primaryDomain = strtolower(trim(str_param('primary_domain')));

    if (empty($u)) err('Username is required');
    if ($err = SysUser::validateUsername($u)) err($err);
    if (strlen($p) < 8) err('Password must be at least 8 characters');
    if (DB::one("SELECT id FROM panel_users WHERE username=?", [$u])) err("Username '$u' is already taken");
    if ($primaryDomain && !preg_match('/^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/', $primaryDomain))
        err("Invalid primary domain name: $primaryDomain");
    if ($primaryDomain && DB::one("SELECT id FROM user_domains WHERE domain=?", [$primaryDomain]))
        err("Domain '$primaryDomain' is already used by another account");

    // 1. Create Linux system user + full /home/{user}/ structure
    $sys = SysUser::create($u, $p, $shell);
    if (!$sys['ok']) err($sys['msg']);

    // 2. Create per-user PHP-FPM pool (ensureFpmPool is idempotent)
    VHost::ensureFpmPool($u, PHP_VER);

    // 3. Insert panel record
    $hash = password_hash($p, PASSWORD_BCRYPT, ['cost' => 12]);
    $uid  = DB::exec(
        "INSERT INTO panel_users (username, password_hash, email, full_name, disk_quota_mb, shell, primary_domain) VALUES (?,?,?,?,?,?,?)",
        [$u, $hash, $email, $fname, $quota, $shell ? '/bin/bash' : '/usr/sbin/nologin', $primaryDomain]
    );

    // 4. If primary domain provided, create Apache vHost + register in domains table
    $vhostResult = null;
    if ($primaryDomain) {
        $webroot = "/home/$u/public_html";
        // VHost::create calls ensureFpmPool internally but it's idempotent (no-op since pool exists)
        $vhostResult = VHost::create($u, $primaryDomain, $webroot, PHP_VER, 'main');
        if ($vhostResult['ok']) {
            DB::exec(
                "INSERT INTO user_domains (user_id, username, domain, type, webroot, php_version, status) VALUES (?,?,?,?,?,?,'active')",
                [$uid, $u, $primaryDomain, 'main', $webroot, PHP_VER]
            );
        }
    }

    Auth::log('user_create', "user=$u domain=$primaryDomain shell=" . ($shell ? '1' : '0'));
    ok("Account '$u' created successfully", [
        'user_id' => $uid,
        'home'    => "/home/$u",
        'webroot' => "/home/$u/public_html",
        'vhost'   => $vhostResult,
    ]);

case 'user_suspend':
    $row = DB::one("SELECT username FROM panel_users WHERE id=?", [int_param('id')]);
    if (!$row) err('Account not found');
    SysUser::suspend($row['username']);
    DB::exec("UPDATE panel_users SET status='suspended' WHERE id=?", [int_param('id')]);
    // Disable all their Apache vhosts
    foreach (DB::q("SELECT domain FROM user_domains WHERE username=?", [$row['username']]) as $d)
        VHost::disable($d['domain']);
    Auth::log('user_suspend', $row['username']);
    ok("Account {$row['username']} suspended");

case 'user_unsuspend':
    $row = DB::one("SELECT username FROM panel_users WHERE id=?", [int_param('id')]);
    if (!$row) err('Account not found');
    SysUser::unsuspend($row['username']);
    DB::exec("UPDATE panel_users SET status='active' WHERE id=?", [int_param('id')]);
    foreach (DB::q("SELECT domain FROM user_domains WHERE username=? AND status='active'", [$row['username']]) as $d)
        VHost::enable($d['domain']);
    Auth::log('user_unsuspend', $row['username']);
    ok("Account {$row['username']} unsuspended");

case 'user_delete':
    $uid = int_param('id');
    $row = DB::one("SELECT username FROM panel_users WHERE id=?", [$uid]);
    if (!$row) err('Account not found');
    $u = $row['username'];

    // Remove all vhosts
    foreach (DB::q("SELECT domain FROM user_domains WHERE username=?", [$u]) as $d) VHost::delete($d['domain']);
    VHost::removeFpmPool($u, PHP_VER);

    // Drop all MariaDB databases
    foreach (DB::q("SELECT db_name, db_user FROM user_databases WHERE username=?", [$u]) as $db) {
        try {
            $pdo = DB::root();
            $pdo->exec("DROP DATABASE IF EXISTS `{$db['db_name']}`");
            $pdo->exec("DROP USER IF EXISTS '{$db['db_user']}'@'localhost'");
        } catch (Exception $e) {}
    }
    $pdo->exec("FLUSH PRIVILEGES");

    // Delete system user + home dir
    SysUser::delete($u);
    // Delete panel records (FK cascade handles children)
    DB::exec("DELETE FROM panel_users WHERE id=?", [$uid]);

    Auth::log('user_delete', $u);
    ok("Account '$u' and all associated data permanently deleted");

case 'user_change_password':
    $row = DB::one("SELECT username FROM panel_users WHERE id=?", [int_param('id')]);
    if (!$row) err('Account not found');
    $np  = str_param('password');
    if (strlen($np) < 8) err('Password must be at least 8 characters');
    SysUser::setPassword($row['username'], $np);
    $hash = password_hash($np, PASSWORD_BCRYPT, ['cost' => 12]);
    DB::exec("UPDATE panel_users SET password_hash=? WHERE id=?", [$hash, int_param('id')]);
    Auth::log('admin_pw_change', $row['username']);
    ok('Password updated');

// ─── Domains (admin overview) ─────────────────────────────────────────────────
case 'domains_list':
    $doms = DB::q("SELECT d.*, p.email FROM user_domains d LEFT JOIN panel_users p ON d.username=p.username ORDER BY d.created_at DESC");
    foreach ($doms as &$d) {
        $d['apache'] = VHost::getStatus($d['domain']);
        $d['ssl_days'] = SSLManager::daysUntilExpiry($d['domain']);
    }
    ok('ok', ['domains' => $doms]);

// ─── Databases (admin overview) ───────────────────────────────────────────────
case 'all_dbs':
    ok('ok', ['dbs' => DBManager::listAll()]);

// ─── Activity log ─────────────────────────────────────────────────────────────
case 'activity_log':
    ok('ok', ['log' => DB::q("SELECT * FROM activity_log ORDER BY created_at DESC LIMIT 500")]);

// ─── Server security info ─────────────────────────────────────────────────────
case 'security_info':
    $f2b = []; exec("sudo fail2ban-client status 2>&1 | head -20", $f2b);
    $ufw = []; exec("sudo ufw status 2>&1 | head -30", $ufw);
    $bans = []; exec("sudo fail2ban-client status sshd 2>&1 | grep 'Banned IP' | head -5", $bans);
    ok('ok', [
        'fail2ban' => implode("\n", $f2b),
        'ufw'      => implode("\n", $ufw),
        'bans'     => implode("\n", $bans),
    ]);

default:
    err("Unknown API action: '$action'");
}
PHPEOF

log "Admin API written"

# ── Admin Panel HTML ──────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/admin/public/tpl_panel.php" << 'HTML'
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WebPanel Admin</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Outfit:wght@300;400;600;800&display=swap" rel="stylesheet">
<style>
:root{--bg:#04080f;--surf:#07101f;--surf2:#0a1628;--brd:#0f1e36;--acc:#00c8f8;--acc2:#6e45e2;--acc3:#00e5a0;--danger:#ff4d6d;--warn:#f59e0b;--ok:#00e5a0;--text:#d6e8ff;--muted:#3d6080;--muted2:#1c3050;--sidebar:245px;--mono:'JetBrains Mono',monospace;--font:'Outfit',sans-serif}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:var(--font);display:flex;min-height:100vh;font-size:14px}
/* SIDEBAR */
.sb{width:var(--sidebar);background:var(--surf);border-right:1px solid var(--brd);display:flex;flex-direction:column;position:fixed;height:100vh;z-index:200;overflow-y:auto}
.sb-logo{padding:1.4rem 1.2rem;border-bottom:1px solid var(--brd);display:flex;align-items:center;gap:.75rem}
.sb-logo .icon{width:36px;height:36px;border-radius:10px;background:linear-gradient(135deg,var(--acc),var(--acc2));display:flex;align-items:center;justify-content:center;font-size:1.1rem;flex-shrink:0}
.sb-logo h1{font-weight:800;font-size:.92rem;background:linear-gradient(135deg,var(--acc),var(--acc2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:.06em}
.sb-logo small{display:block;color:var(--muted);font-size:.6rem;font-family:var(--mono);letter-spacing:.08em}
.nav-grp{padding:.75rem .75rem .2rem;font-size:.58rem;color:var(--muted2);letter-spacing:.18em;text-transform:uppercase;font-family:var(--mono)}
nav a{display:flex;align-items:center;gap:.65rem;padding:.58rem 1rem;color:var(--muted);text-decoration:none;font-size:.8rem;transition:.15s;border-left:2px solid transparent;margin:.08rem .4rem;border-radius:0 8px 8px 0}
nav a span.ic{font-size:.85rem;width:16px;text-align:center;flex-shrink:0}
nav a:hover{color:var(--text);background:rgba(0,200,248,.05)}
nav a.on{color:var(--acc);background:rgba(0,200,248,.08);border-left-color:var(--acc);font-weight:600}
.sb-foot{margin-top:auto;padding:1rem;border-top:1px solid var(--brd)}
.sb-foot .u{font-weight:700;font-size:.82rem;color:var(--text)}
.sb-foot .r{display:inline-block;background:rgba(110,69,226,.18);color:var(--acc2);border-radius:20px;padding:.12rem .6rem;font-size:.6rem;font-family:var(--mono);margin:.2rem 0 .4rem}
.sb-foot a{color:var(--muted);text-decoration:none;font-size:.75rem;display:block}
.sb-foot a:hover{color:var(--danger)}
/* MAIN */
.main{margin-left:var(--sidebar);flex:1;min-width:0}
.topbar{background:var(--surf);border-bottom:1px solid var(--brd);padding:.65rem 1.6rem;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100}
.topbar-l{display:flex;align-items:center;gap:.8rem}
.topbar h2{font-size:.78rem;font-family:var(--mono);color:var(--muted);letter-spacing:.1em;text-transform:uppercase}
.topbar-r{display:flex;align-items:center;gap:.8rem}
#clock{font-family:var(--mono);font-size:.75rem;color:var(--muted)}
#svc-dots{display:flex;gap:.35rem}
.dot{width:8px;height:8px;border-radius:50%;cursor:default;transition:.3s}
.content{padding:1.4rem 1.6rem}
/* SECTIONS */
.sec{display:none}.sec.on{display:block}
.sh{display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:1.4rem;gap:1rem;flex-wrap:wrap}
.sh h2{font-size:1.15rem;font-weight:800}
.sh p{color:var(--muted);font-size:.78rem;margin-top:.15rem}
/* CARDS */
.card{background:var(--surf);border:1px solid var(--brd);border-radius:14px;padding:1.2rem;margin-bottom:1rem}
.ct{font-size:.62rem;color:var(--muted);text-transform:uppercase;letter-spacing:.14em;font-family:var(--mono);margin-bottom:.8rem;display:flex;align-items:center;gap:.35rem}
/* STATS */
.sg{display:grid;grid-template-columns:repeat(4,1fr);gap:.9rem;margin-bottom:1.2rem}
.sc{background:var(--surf);border:1px solid var(--brd);border-radius:13px;padding:1.1rem 1.3rem;position:relative;overflow:hidden;transition:border-color .2s}
.sc::after{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:var(--sc-acc,var(--acc))}
.sc:hover{border-color:var(--sc-acc,var(--acc))}
.sl{font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);margin-bottom:.4rem}
.sv{font-size:1.75rem;font-weight:800;color:var(--text);line-height:1}
.ss{font-size:.68rem;color:var(--muted);margin-top:.25rem}
.sicon{position:absolute;right:.9rem;top:50%;transform:translateY(-50%);font-size:1.8rem;opacity:.12}
/* SERVICES */
.svgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:.75rem}
.svc{background:var(--surf2);border:1px solid var(--brd);border-radius:12px;padding:.95rem;text-align:center;transition:border-color .2s}
.svc:hover{border-color:var(--muted)}
.svc-n{font-size:.62rem;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);margin-bottom:.4rem}
.svc-s{margin-bottom:.65rem}
.svc-b{display:flex;gap:.25rem;justify-content:center;flex-wrap:wrap}
/* TABLE */
.tw{overflow-x:auto;border-radius:12px;border:1px solid var(--brd)}
table{width:100%;border-collapse:collapse;font-size:.8rem}
thead{background:var(--surf2)}
th{padding:.65rem .9rem;text-align:left;font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);border-bottom:1px solid var(--brd);white-space:nowrap}
td{padding:.6rem .9rem;border-bottom:1px solid var(--brd);vertical-align:middle}
tr:last-child td{border:none}
tr:hover td{background:rgba(0,200,248,.02)}
/* BADGES */
.b{display:inline-flex;align-items:center;padding:.14rem .48rem;border-radius:20px;font-size:.6rem;font-weight:700;letter-spacing:.04em;font-family:var(--mono);white-space:nowrap}
.bg{background:rgba(0,229,160,.1);color:var(--ok);border:1px solid rgba(0,229,160,.2)}
.br{background:rgba(255,77,109,.1);color:var(--danger);border:1px solid rgba(255,77,109,.2)}
.bb{background:rgba(0,200,248,.1);color:var(--acc);border:1px solid rgba(0,200,248,.2)}
.bp{background:rgba(110,69,226,.1);color:var(--acc2);border:1px solid rgba(110,69,226,.2)}
.bo{background:rgba(245,158,11,.1);color:var(--warn);border:1px solid rgba(245,158,11,.2)}
/* BUTTONS */
.btn{display:inline-flex;align-items:center;gap:.35rem;padding:.4rem .95rem;border:none;border-radius:8px;cursor:pointer;font-family:var(--font);font-size:.76rem;font-weight:600;transition:.15s;text-decoration:none;white-space:nowrap}
.btn:disabled{opacity:.4;cursor:not-allowed}
.btp{background:linear-gradient(135deg,var(--acc),#009bc5);color:#04080f}
.btp:hover:not(:disabled){box-shadow:0 4px 14px rgba(0,200,248,.3)}
.btv{background:linear-gradient(135deg,var(--acc2),#4d2eb5);color:#fff}
.btd{background:rgba(255,77,109,.12);color:var(--danger);border:1px solid rgba(255,77,109,.25)}
.btd:hover{background:var(--danger);color:#fff}
.btw{background:rgba(245,158,11,.12);color:var(--warn);border:1px solid rgba(245,158,11,.25)}
.btw:hover{background:var(--warn);color:#000}
.bts{background:rgba(0,229,160,.12);color:var(--ok);border:1px solid rgba(0,229,160,.25)}
.bts:hover{background:var(--ok);color:#000}
.btg{background:rgba(255,255,255,.04);color:var(--muted);border:1px solid var(--brd)}
.btg:hover{background:rgba(255,255,255,.07);color:var(--text)}
.sm{padding:.28rem .65rem;font-size:.7rem}
.xs{padding:.18rem .48rem;font-size:.62rem}
/* FORM */
.fg{display:grid;gap:.8rem;margin-bottom:.85rem}
.fg2{grid-template-columns:1fr 1fr}
.fg3{grid-template-columns:1fr 1fr 1fr}
.fg label{display:block;color:var(--muted);font-size:.6rem;text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);margin-bottom:.35rem}
.fg input,.fg select,.fg textarea{width:100%;background:rgba(0,200,248,.03);border:1px solid var(--brd);border-radius:8px;padding:.55rem .85rem;color:var(--text);font-family:var(--font);font-size:.83rem;transition:.2s}
.fg input:focus,.fg select:focus,.fg textarea:focus{outline:none;border-color:var(--acc);background:rgba(0,200,248,.06)}
.fg select option{background:var(--surf)}
.fhint{font-size:.65rem;color:var(--muted);margin-top:.25rem}
/* ALERT */
.al{padding:.6rem 1rem;border-radius:9px;margin-bottom:.75rem;font-size:.8rem;display:none;animation:fi .2s}
.aok{background:rgba(0,229,160,.08);border:1px solid rgba(0,229,160,.2);color:var(--ok)}
.aerr{background:rgba(255,77,109,.08);border:1px solid rgba(255,77,109,.2);color:var(--danger)}
@keyframes fi{from{opacity:0;transform:translateY(-3px)}to{opacity:1;transform:none}}
/* MODAL */
.mo{display:none;position:fixed;inset:0;background:rgba(0,0,0,.78);z-index:999;align-items:center;justify-content:center;backdrop-filter:blur(4px)}
.mo.on{display:flex}
.mob{background:var(--surf);border:1px solid var(--brd);border-radius:16px;padding:1.8rem;width:min(520px,95vw);max-height:88vh;overflow-y:auto;box-shadow:0 50px 100px rgba(0,0,0,.6)}
.mob h3{font-size:.95rem;margin-bottom:1.2rem;color:var(--text)}
.mof{display:flex;gap:.5rem;justify-content:flex-end;margin-top:1.1rem;padding-top:.9rem;border-top:1px solid var(--brd)}
/* LOG */
.lbox{background:#020810;border:1px solid var(--brd);border-radius:10px;padding:.9rem;font-family:var(--mono);font-size:.72rem;line-height:1.8;max-height:380px;overflow-y:auto;color:#60d0ff}
.lr{display:flex;gap:.9rem;padding:.12rem 0;border-bottom:1px solid rgba(15,30,54,.8)}
.lt{color:var(--muted2);min-width:140px;flex-shrink:0}
.lu{color:var(--acc);min-width:75px;flex-shrink:0}
.la{color:var(--acc2);min-width:110px;flex-shrink:0}
.ld{color:#3a5870;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
/* DISK BAR */
.db{background:var(--brd);border-radius:3px;height:4px;overflow:hidden;margin-top:.25rem}
.dbf{height:100%;border-radius:3px;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .5s}
/* USER CARDS */
.ug{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:.9rem}
.uc{background:var(--surf);border:1px solid var(--brd);border-radius:13px;padding:1.1rem;transition:border-color .2s}
.uc:hover{border-color:var(--muted)}
.ua{width:42px;height:42px;border-radius:11px;background:linear-gradient(135deg,var(--acc),var(--acc2));display:flex;align-items:center;justify-content:center;font-weight:800;font-size:1rem;color:#04080f;flex-shrink:0}
.tabs{display:flex;gap:.25rem;margin-bottom:1rem;border-bottom:1px solid var(--brd)}
.tab{padding:.45rem 1rem;color:var(--muted);cursor:pointer;font-size:.78rem;font-weight:600;border-bottom:2px solid transparent;transition:.15s;margin-bottom:-1px}
.tab:hover{color:var(--text)}
.tab.on{color:var(--acc);border-bottom-color:var(--acc)}
.tp{display:none}.tp.on{display:block}
</style>
</head><body>
<aside class="sb">
  <div class="sb-logo">
    <div class="icon">🖥</div>
    <div><h1>WEBPANEL</h1><small>ADMIN v3.0</small></div>
  </div>
  <div class="nav-grp">Overview</div>
  <nav>
    <a href="#" class="on" data-s="dashboard"><span class="ic">📊</span>Dashboard</a>
    <a href="#" data-s="services"><span class="ic">⚙️</span>Services</a>
    <div class="nav-grp">Hosting</div>
    <a href="#" data-s="accounts"><span class="ic">👥</span>Accounts</a>
    <a href="#" data-s="domains"><span class="ic">🌐</span>Domains</a>
    <a href="#" data-s="databases"><span class="ic">🗄</span>Databases</a>
    <div class="nav-grp">System</div>
    <a href="#" data-s="security"><span class="ic">🔒</span>Security</a>
    <a href="#" data-s="actlog"><span class="ic">📋</span>Activity Log</a>
    <a href="/phpmyadmin/" target="_blank"><span class="ic">🗂</span>phpMyAdmin ↗</a>
  </nav>
  <div class="sb-foot">
    <div class="u"><?=htmlspecialchars(Auth::user())?></div>
    <span class="r">ADMINISTRATOR</span>
    <a href="?page=logout">← Sign Out</a>
  </div>
</aside>

<div class="main">
<div class="topbar">
  <div class="topbar-l"><h2 id="ptitle">DASHBOARD</h2></div>
  <div class="topbar-r">
    <span id="clock"></span>
    <div id="svc-dots"></div>
  </div>
</div>
<div class="content">

<!-- DASHBOARD -->
<div id="s-dashboard" class="sec on">
  <div class="sg" id="sg"></div>
  <div class="card"><div class="ct">⚙ SERVICES</div><div class="svgrid" id="qsvcs"></div></div>
</div>

<!-- SERVICES -->
<div id="s-services" class="sec">
  <div class="sh"><div><h2>Services</h2><p>Start, stop, restart and reload server daemons</p></div>
    <button class="btn btg sm" onclick="loadSvcs()">↻ Refresh</button></div>
  <div id="al-svc" class="al"></div>
  <div class="card"><div class="ct">OUTPUT</div><div class="lbox" id="svc-out" style="min-height:50px;color:#00e5a0"></div></div>
  <div class="svgrid" id="svgrid-full"></div>
</div>

<!-- ACCOUNTS -->
<div id="s-accounts" class="sec">
  <div class="sh"><div><h2>Hosting Accounts</h2><p>Each account = Linux system user + /home/{user}/public_html/</p></div>
    <button class="btn btp" onclick="show_mo('mo-newuser')">+ New Account</button></div>
  <div id="al-accounts" class="al"></div>
  <div class="tabs">
    <div class="tab on" onclick="stab('ut','cards')">Cards</div>
    <div class="tab" onclick="stab('ut','table')">Table</div>
  </div>
  <div id="ut-cards" class="tp on"><div class="ug" id="ucards"></div></div>
  <div id="ut-table" class="tp">
    <div class="tw"><table><thead><tr>
      <th>Username</th><th>Full Name</th><th>Email</th><th>Status</th>
      <th>Domains</th><th>DBs</th><th>Disk</th><th>Created</th><th>Actions</th>
    </tr></thead><tbody id="utable"></tbody></table></div>
  </div>
</div>

<!-- DOMAINS -->
<div id="s-domains" class="sec">
  <div class="sh"><div><h2>All Domains</h2><p>Overview of every domain hosted on this server</p></div>
    <button class="btn btg sm" onclick="loadDomains()">↻ Refresh</button></div>
  <div class="tw"><table><thead><tr>
    <th>Domain</th><th>Account</th><th>Type</th><th>Web Root</th><th>SSL</th><th>Apache</th><th>Status</th><th>Added</th>
  </tr></thead><tbody id="dtbody"></tbody></table></div>
</div>

<!-- DATABASES -->
<div id="s-databases" class="sec">
  <div class="sh"><div><h2>All Databases</h2><p>MariaDB databases — username-prefixed like cPanel</p></div>
    <button class="btn btg sm" onclick="loadAllDBs()">↻ Refresh</button></div>
  <div class="tw"><table><thead><tr><th>Database</th><th>DB User</th><th>Account</th><th>Created</th></tr></thead>
  <tbody id="dbtbody"></tbody></table></div>
</div>

<!-- SECURITY -->
<div id="s-security" class="sec">
  <div class="sh"><div><h2>Security</h2><p>Fail2Ban bans, UFW firewall rules</p></div>
    <button class="btn btg sm" onclick="loadSec()">↻ Refresh</button></div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem">
    <div class="card"><div class="ct">FAIL2BAN</div><pre class="lbox" id="f2b" style="height:240px">Loading…</pre>
      <div style="margin-top:.6rem;display:flex;gap:.4rem">
        <button class="btn btg xs" onclick="loadSec()">Refresh</button>
        <button class="btn btw xs" onclick="svcact('fail2ban','restart')">Restart F2B</button>
      </div></div>
    <div class="card"><div class="ct">UFW FIREWALL</div><pre class="lbox" id="ufw" style="height:240px">Loading…</pre></div>
  </div>
</div>

<!-- ACTIVITY LOG -->
<div id="s-actlog" class="sec">
  <div class="sh"><div><h2>Activity Log</h2><p>All admin and user actions (last 500)</p></div>
    <button class="btn btg sm" onclick="loadLog()">↻ Refresh</button></div>
  <div class="card"><div class="lbox" id="actlog" style="max-height:620px"></div></div>
</div>

</div><!-- .content -->
</div><!-- .main -->

<!-- MODALS -->
<div class="mo" id="mo-newuser">
  <div class="mob">
    <h3>➕ Create Hosting Account</h3>
    <div id="al-newuser" class="al"></div>
    <div class="fg fg2">
      <div><label>Username *</label><input id="nu-u" placeholder="jsmith" oninput="this.value=this.value.toLowerCase().replace(/[^a-z0-9_]/g,'')"><div class="fhint">3–32 chars · a-z 0-9 _ · Creates Linux user + /home/username/</div></div>
      <div><label>Password *</label><input id="nu-p" type="password" placeholder="min 8 chars">
        <div class="fhint"><a href="#" onclick="genp();return false" style="color:var(--acc);text-decoration:none">⚡ Auto-generate</a></div></div>
    </div>
    <div class="fg">
      <div><label>Primary Domain</label><input id="nu-dom" placeholder="example.com" autocomplete="off"><div class="fhint">Web root will be /home/username/public_html/ — leave blank to add domain later via user panel</div></div>
    </div>
    <div class="fg fg2">
      <div><label>Full Name</label><input id="nu-fn" placeholder="John Smith"></div>
      <div><label>Email Address</label><input id="nu-em" type="email" placeholder="john@example.com"></div>
    </div>
    <div class="fg fg2">
      <div><label>Disk Quota (MB)</label><input id="nu-q" type="number" value="5120" min="256" max="102400"><div class="fhint">1024 MB = 1 GB</div></div>
      <div><label>Shell Access</label>
        <select id="nu-sh"><option value="">No shell (FTP/SFTP only — recommended)</option><option value="1">Yes (/bin/bash)</option></select>
        <div class="fhint">Enable only for trusted developers needing SSH.</div></div>
    </div>
    <div class="mof">
      <button class="btn btg" onclick="hide_mo('mo-newuser')">Cancel</button>
      <button class="btn btp" onclick="createAccount()">Create Account →</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-chpass">
  <div class="mob">
    <h3>🔑 Change Password</h3>
    <div class="fg"><div><label>Account</label><input id="cp-u" readonly style="opacity:.6"></div>
    <div><label>New Password *</label><input id="cp-p" type="password" placeholder="min 8 chars"></div></div>
    <input type="hidden" id="cp-id">
    <div class="mof">
      <button class="btn btg" onclick="hide_mo('mo-chpass')">Cancel</button>
      <button class="btn btp" onclick="chpass()">Update Password</button>
    </div>
  </div>
</div>

<script>
// ── Core ──────────────────────────────────────────────────────────────────────
const api = (a,d={}) => fetch('?api='+a,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).catch(e=>({ok:false,msg:e.message}));
const $  = id => document.getElementById(id);
const rp = (n=18) => [...crypto.getRandomValues(new Uint8Array(n))].map(b=>'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%'[b%58]).join('');

// Navigation
const SMAP = {dashboard:loadDash,services:loadSvcs,accounts:loadAccounts,domains:loadDomains,databases:loadAllDBs,security:loadSec,actlog:loadLog};
function nav(s){
  document.querySelectorAll('.sec').forEach(e=>e.classList.remove('on'));
  document.querySelectorAll('nav a[data-s]').forEach(e=>e.classList.remove('on'));
  $('s-'+s)?.classList.add('on');
  document.querySelector(`nav a[data-s="${s}"]`)?.classList.add('on');
  $('ptitle').textContent=s.toUpperCase();
  SMAP[s]?.();
}
document.querySelectorAll('nav a[data-s]').forEach(a=>a.addEventListener('click',e=>{e.preventDefault();nav(a.dataset.s)}));

// Tabs
function stab(g,t){
  document.querySelectorAll(`[id^="${g}-"]`).forEach(e=>e.classList.remove('on'));
  document.querySelectorAll('.tab').forEach(e=>e.classList.remove('on'));
  $(`${g}-${t}`)?.classList.add('on');
  event.target?.classList.add('on');
}

// Modals
function show_mo(id){$(id).classList.add('on')}
function hide_mo(id){$(id).classList.remove('on')}
document.querySelectorAll('.mo').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('on')}));

// Alerts
function al(id,msg,ok){const e=$(id);e.className='al '+(ok?'aok':'aerr');e.textContent=msg;e.style.display='block';setTimeout(()=>e.style.display='none',7000)}

// Helpers
const badge=(t,c)=>`<span class="b ${c}">${t}</span>`;
function genp(){$('nu-p').value=rp(16);$('nu-p').type='text'}

// ── Dashboard ─────────────────────────────────────────────────────────────────
async function loadDash(){
  const [st,sv]=await Promise.all([api('server_stats'),api('service_status')]);
  if(st.load){
    $('sg').innerHTML=`
      <div class="sc" style="--sc-acc:var(--acc)"><div class="sl">Load Average</div><div class="sv">${(st.load||[]).join(' / ')}</div><div class="ss">${st.uptime}</div><span class="sicon">⚡</span></div>
      <div class="sc" style="--sc-acc:var(--acc2)"><div class="sl">Memory</div><div class="sv">${st.mem_used}/${st.mem_total} MB</div><div class="ss">${st.mem_pct}% used</div><span class="sicon">🧠</span></div>
      <div class="sc" style="--sc-acc:var(--acc3)"><div class="sl">Disk</div><div class="sv">${st.disk_used}</div><div class="ss">${st.disk_pct} of ${st.disk_size}</div><span class="sicon">💾</span></div>
      <div class="sc" style="--sc-acc:var(--warn)"><div class="sl">Accounts</div><div class="sv">${st.accounts}</div><div class="ss">${st.domains} domains · ${st.dbs} DBs</div><span class="sicon">👥</span></div>`;
  }
  if(sv.services){rendDots(sv.services);rendQsvcs(sv.services);}
}
function rendDots(s){
  $('svc-dots').innerHTML=Object.entries(s).map(([k,v])=>
    `<div class="dot" title="${k}: ${v}" style="background:${v==='active'?'var(--ok)':'var(--danger)'};${v==='active'?'box-shadow:0 0 6px var(--ok)':''}"></div>`
  ).join('');
}
function rendQsvcs(s){
  $('qsvcs').innerHTML=Object.entries(s).map(([k,v])=>
    `<div class="svc"><div class="svc-n">${k}</div><div class="svc-s">${badge(v,v==='active'?'bg':'br')}</div></div>`
  ).join('');
}

// ── Services ──────────────────────────────────────────────────────────────────
const SVCS=['apache2','mariadb','php<?=PHP_VER?>-fpm','redis-server','fail2ban','vsftpd','postfix','memcached'];
async function loadSvcs(){
  const sv=await api('service_status');
  $('svgrid-full').innerHTML=SVCS.map(s=>{const v=sv.services?.[s]||'?';return`
    <div class="svc"><div class="svc-n">${s}</div><div class="svc-s">${badge(v,v==='active'?'bg':'br')}</div>
    <div class="svc-b">
      <button class="btn bts xs" onclick="svcact('${s}','start')">Start</button>
      <button class="btn btd xs" onclick="svcact('${s}','stop')">Stop</button>
      <button class="btn btp xs" onclick="svcact('${s}','restart')">Restart</button>
      <button class="btn btv xs" onclick="svcact('${s}','reload')">Reload</button>
    </div></div>`;}).join('');
  if(sv.services) rendDots(sv.services);
}
async function svcact(svc,act){
  $('svc-out').textContent=`▶ systemctl ${act} ${svc}…`;
  const r=await api('service_action',{service:svc,action:act});
  $('svc-out').textContent=r.msg||'Done';
  loadSvcs();
}

// ── Accounts ──────────────────────────────────────────────────────────────────
async function loadAccounts(){
  const r=await api('users_list');
  const us=r.users||[];
  // Cards view
  $('ucards').innerHTML=us.length?us.map(u=>{
    const pct=u.disk_quota_mb?Math.min(100,Math.round(u.disk_used_mb/u.disk_quota_mb*100)):0;
    const init=(u.full_name||u.username).substring(0,2).toUpperCase();
    return`<div class="uc">
      <div style="display:flex;gap:.75rem;align-items:flex-start;margin-bottom:.75rem">
        <div class="ua">${init}</div>
        <div style="flex:1;min-width:0">
          <div style="font-weight:700;font-size:.9rem">${u.username}</div>
          <div style="font-size:.72rem;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${u.primary_domain||u.email||'—'}</div>
        </div>
        ${badge(u.status,u.status==='active'?'bg':'br')}
      </div>
      <div style="display:flex;gap:.35rem;flex-wrap:wrap;margin-bottom:.6rem">
        ${badge(u.domain_count+' domains','bb')}
        ${badge(u.db_count+' DBs','bp')}
        ${badge(u.disk_used_mb+'/'+(u.disk_quota_mb||'∞')+' MB','bo')}
      </div>
      <div style="font-size:.68rem;color:var(--muted);margin-bottom:.3rem;font-family:var(--mono)">/home/${u.username}/public_html</div>
      <div class="db"><div class="dbf" style="width:${pct}%"></div></div>
      <div style="font-size:.62rem;color:var(--muted);margin:.2rem 0 .75rem">${pct}% of ${u.disk_quota_mb} MB</div>
      <div style="display:flex;gap:.3rem;flex-wrap:wrap">
        <a href="//<?=$_SERVER['HTTP_HOST']?>:<?=USER_PORT?>/?su=${u.username}" target="_blank" class="btn btp xs">Manage →</a>
        <button class="btn xs btg" onclick="opencp(${u.id},'${u.username}')">🔑 Pass</button>
        ${u.status==='active'
          ?`<button class="btn xs btw" onclick="suspend(${u.id})">Suspend</button>`
          :`<button class="btn xs bts" onclick="unsuspend(${u.id})">Unsuspend</button>`}
        <button class="btn xs btd" onclick="del(${u.id},'${u.username}')">Delete</button>
      </div>
    </div>`;
  }).join(''):`<div style="color:var(--muted);text-align:center;padding:3rem;grid-column:1/-1">No accounts yet — create one above.</div>`;
  // Table view
  $('utable').innerHTML=us.map(u=>`<tr>
    <td><strong>${u.username}</strong></td><td>${u.full_name||'—'}</td><td>${u.email||'—'}</td>
    <td>${badge(u.status,u.status==='active'?'bg':'br')}</td>
    <td>${u.domain_count}</td><td>${u.db_count}</td>
    <td>${u.disk_used_mb}/${u.disk_quota_mb} MB</td>
    <td style="font-size:.7rem;color:var(--muted)">${u.created_at?.substring(0,10)}</td>
    <td><div style="display:flex;gap:.25rem">
      <a href="//<?=$_SERVER['HTTP_HOST']?>:<?=USER_PORT?>/?su=${u.username}" target="_blank" class="btn xs btp">Manage</a>
      <button class="btn xs btg" onclick="opencp(${u.id},'${u.username}')">🔑</button>
      ${u.status==='active'
        ?`<button class="btn xs btw" onclick="suspend(${u.id})">Suspend</button>`
        :`<button class="btn xs bts" onclick="unsuspend(${u.id})">Unsuspend</button>`}
      <button class="btn xs btd" onclick="del(${u.id},'${u.username}')">×</button>
    </div></td>
  </tr>`).join('');
}
async function createAccount(){
  const r=await api('user_create',{username:$('nu-u').value,password:$('nu-p').value,primary_domain:$('nu-dom').value,full_name:$('nu-fn').value,email:$('nu-em').value,quota_mb:$('nu-q').value,shell_access:$('nu-sh').value});
  al('al-newuser',r.msg,r.ok);
  if(r.ok){setTimeout(()=>hide_mo('mo-newuser'),1600);loadAccounts();}
}
async function suspend(id){if(!confirm('Suspend this account? Their sites go offline.')) return;const r=await api('user_suspend',{id});al('al-accounts',r.msg,r.ok);loadAccounts();}
async function unsuspend(id){const r=await api('user_unsuspend',{id});al('al-accounts',r.msg,r.ok);loadAccounts();}
async function del(id,u){
  if(!confirm(`DELETE "${u}"?\n\nThis removes:\n• Linux system user\n• All files in /home/${u}/\n• All domains and vhosts\n• All databases\n\nThis CANNOT be undone.`)) return;
  const r=await api('user_delete',{id});al('al-accounts',r.msg,r.ok);loadAccounts();
}
function opencp(id,u){$('cp-id').value=id;$('cp-u').value=u;$('cp-p').value='';show_mo('mo-chpass');}
async function chpass(){const r=await api('user_change_password',{id:$('cp-id').value,password:$('cp-p').value});al('al-accounts',r.msg,r.ok);if(r.ok)hide_mo('mo-chpass');}

// ── Domains ───────────────────────────────────────────────────────────────────
async function loadDomains(){
  const r=await api('domains_list');
  const ds=r.domains||[];
  $('dtbody').innerHTML=ds.length?ds.map(d=>`<tr>
    <td><strong>${d.domain}</strong></td>
    <td>${badge(d.username,'bb')}</td>
    <td>${badge(d.type,'bp')}</td>
    <td style="font-size:.7rem;color:var(--muted);font-family:var(--mono);max-width:200px;overflow:hidden;text-overflow:ellipsis">${d.webroot.replace('/home/'+d.username,'~')}</td>
    <td>${d.ssl_enabled=='1'?badge('SSL ✓','bg')+(d.ssl_days!==null?` <span style="font-size:.6rem;color:var(--muted)">${d.ssl_days}d</span>`:''):badge('No SSL','br')}</td>
    <td>${badge(d.apache||'?',d.apache==='enabled'?'bg':'br')}</td>
    <td>${badge(d.status,d.status==='active'?'bg':'br')}</td>
    <td style="font-size:.7rem;color:var(--muted)">${d.created_at?.substring(0,10)}</td>
  </tr>`).join(''):`<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:2rem">No domains</td></tr>`;
}

// ── Databases ─────────────────────────────────────────────────────────────────
async function loadAllDBs(){
  const r=await api('all_dbs');
  const ds=r.dbs||[];
  $('dbtbody').innerHTML=ds.length?ds.map(d=>`<tr>
    <td><strong>${d.db_name}</strong></td>
    <td><code style="font-size:.75rem;color:var(--acc)">${d.db_user}</code></td>
    <td>${badge(d.username,'bb')}</td>
    <td style="font-size:.7rem;color:var(--muted)">${d.created_at?.substring(0,10)}</td>
  </tr>`).join(''):`<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:2rem">No databases</td></tr>`;
}

// ── Security ──────────────────────────────────────────────────────────────────
async function loadSec(){
  const r=await api('security_info');
  $('f2b').textContent=r.fail2ban||'No data';
  $('ufw').textContent=r.ufw||'No data';
}

// ── Activity Log ──────────────────────────────────────────────────────────────
async function loadLog(){
  const r=await api('activity_log');
  const rows=r.log||[];
  $('actlog').innerHTML=rows.length?rows.map(l=>`<div class="lr">
    <span class="lt">${l.created_at}</span>
    <span class="lu">${l.username||'—'}</span>
    <span class="la">${l.action||''}</span>
    <span class="ld">${l.detail||''}</span>
    <span style="color:var(--muted2);font-size:.65rem;margin-left:auto;flex-shrink:0">${l.ip}</span>
  </div>`).join(''):'<div style="color:var(--muted);padding:1rem">No activity yet</div>';
}

// ── Clock + init ──────────────────────────────────────────────────────────────
setInterval(()=>$('clock').textContent=new Date().toLocaleTimeString(),1000);
loadDash();
setInterval(loadDash,30000);
</script>
</body></html>
HTML

log "Admin panel HTML written"

# =============================================================================
# STEP 7 — User Panel
# =============================================================================
hdr "Step 7 · User Panel"

# ── User index (router) ──────────────────────────────────────────────────────
cat > "${PANEL_DIR}/user/public/index.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/bootstrap.php';

// Admin "switch into user" feature: ?su=username
// Only admin sessions can use this
if (isset($_GET['su'])) {
    Auth::check('admin');
    $su  = preg_replace('/[^a-z0-9_]/', '', strtolower($_GET['su']));
    $row = DB::one("SELECT * FROM panel_users WHERE username = ? AND role = 'user'", [$su]);
    if ($row) {
        $_SESSION['uid']      = $row['id'];
        $_SESSION['user']     = $row['username'];
        $_SESSION['role']     = $row['role'];
        $_SESSION['ts']       = time();
        $_SESSION['su_admin'] = true; // remember we switched
    }
    header('Location: /'); exit;
}

$page = $_GET['page'] ?? 'overview';

// JSON API endpoint
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_GET['api'])) {
    Auth::check();
    header('Content-Type: application/json');
    require_once __DIR__ . '/api.php';
    exit;
}

if ($page === 'logout') Auth::logout();

if ($page === 'login') {
    $err = '';
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        if (Auth::login($_POST['username'] ?? '', $_POST['password'] ?? '')) {
            header('Location: /'); exit;
        }
        $err = 'Invalid username or password.';
    }
    include __DIR__ . '/tpl_login.php';
    exit;
}

// phpinfo page — inside user sandbox
if ($page === 'phpinfo') {
    Auth::check();
    phpinfo();
    exit;
}

Auth::check();
include __DIR__ . '/tpl_panel.php';
PHPEOF

# ── User login ───────────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/user/public/tpl_login.php" <<'PHPEOF'
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WebPanel — Login</title>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Outfit:wght@400;700;800&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#06020f;--surf:#0d0820;--brd:#1a1038;--acc:#9b73ff;--acc2:#4fa8ff;--text:#ede8ff;--muted:#6a5a8a;--red:#ff6b88}
body{background:var(--bg);min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:'Outfit',sans-serif}
.bg{position:fixed;inset:0;background:radial-gradient(ellipse at 30% 40%,rgba(155,115,255,.09),transparent 55%),radial-gradient(ellipse at 70% 60%,rgba(79,168,255,.07),transparent 55%)}
.card{position:relative;background:var(--surf);border:1px solid var(--brd);border-radius:20px;padding:2.8rem 2.3rem;width:400px;box-shadow:0 40px 80px rgba(0,0,0,.6)}
.logo{text-align:center;margin-bottom:2.2rem}
.logo-icon{width:56px;height:56px;border-radius:14px;background:linear-gradient(135deg,var(--acc),var(--acc2));display:flex;align-items:center;justify-content:center;font-size:1.6rem;margin:0 auto .8rem}
.logo h1{font-weight:800;font-size:1.55rem;background:linear-gradient(135deg,var(--acc),var(--acc2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:.05em}
.logo p{color:var(--muted);font-size:.7rem;font-family:'JetBrains Mono',monospace;margin-top:.25rem;letter-spacing:.1em}
.fg{margin-bottom:1rem}
.fg label{display:block;color:var(--muted);font-size:.62rem;text-transform:uppercase;letter-spacing:.12em;font-family:'JetBrains Mono',monospace;margin-bottom:.38rem}
.fg input{width:100%;background:rgba(155,115,255,.05);border:1px solid var(--brd);border-radius:10px;padding:.72rem 1rem;color:var(--text);font-family:'Outfit',sans-serif;font-size:.88rem;transition:.2s}
.fg input:focus{outline:none;border-color:var(--acc);background:rgba(155,115,255,.09)}
.btn{width:100%;background:linear-gradient(135deg,var(--acc),var(--acc2));border:none;border-radius:10px;padding:.82rem;color:#06020f;font-family:'Outfit',sans-serif;font-weight:800;font-size:.92rem;cursor:pointer;letter-spacing:.04em}
.btn:hover{opacity:.92}
.err{background:rgba(255,107,136,.08);border:1px solid rgba(255,107,136,.25);color:var(--red);border-radius:8px;padding:.6rem 1rem;font-size:.8rem;text-align:center;margin-bottom:.9rem}
</style></head><body>
<div class="bg"></div>
<div class="card">
  <div class="logo"><div class="logo-icon">🌐</div><h1>WEBPANEL</h1><p>HOSTING CONTROL PANEL</p></div>
  <?php if($err): ?><div class="err"><?=htmlspecialchars($err)?></div><?php endif; ?>
  <form method="POST">
    <div class="fg"><label>Username</label><input type="text" name="username" required autofocus autocomplete="username"></div>
    <div class="fg"><label>Password</label><input type="password" name="password" required autocomplete="current-password"></div>
    <button type="submit" class="btn">SIGN IN →</button>
  </form>
</div>
</body></html>
PHPEOF

# ── User API ──────────────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/user/public/api.php" <<'PHPEOF'
<?php
$action  = $_GET['api'] ?? '';
$data    = json_decode(file_get_contents('php://input'), true) ?? $_POST;
$me      = Auth::user();
$myUid   = Auth::uid();
$fm      = new FileManager($me);

function ok(string $msg, array $e = []): void { echo json_encode(['ok'=>true,'msg'=>$msg]+$e); exit; }
function err(string $msg): void               { echo json_encode(['ok'=>false,'msg'=>$msg]); exit; }
function sp(string $k): string  { global $data; return trim((string)($data[$k]??'')); }
function ip(string $k): int     { global $data; return (int)($data[$k]??0); }

switch ($action) {

// ── Overview ──────────────────────────────────────────────────────────────────
case 'my_info':
    $u    = DB::one("SELECT * FROM panel_users WHERE id=?", [$myUid]);
    $used = SysUser::diskUsage($me);
    DB::exec("UPDATE panel_users SET disk_used_mb=? WHERE id=?", [$used, $myUid]);
    ok('ok', [
        'user'     => array_intersect_key($u, array_flip(['username','email','full_name','disk_quota_mb','created_at'])),
        'disk_used'=> $used,
        'disk_pct' => $u['disk_quota_mb'] > 0 ? round($used/$u['disk_quota_mb']*100,1) : 0,
        'domains'  => (int)DB::one("SELECT COUNT(*) c FROM user_domains WHERE username=?",[$me])['c'],
        'dbs'      => (int)DB::one("SELECT COUNT(*) c FROM user_databases WHERE username=?",[$me])['c'],
        'crons'    => (int)DB::one("SELECT COUNT(*) c FROM cron_jobs WHERE username=?",[$me])['c'],
        'home'     => "/home/$me",
        'php_ver'  => PHP_VERSION,
        'hostname' => HOSTNAME,
    ]);

// ── Domains ───────────────────────────────────────────────────────────────────
case 'domains_list':
    $doms = DB::q("SELECT * FROM user_domains WHERE username=? ORDER BY type,created_at", [$me]);
    foreach ($doms as &$d) {
        $d['apache_status'] = VHost::getStatus($d['domain']);
        $d['ssl_expiry']    = SSLManager::expiry($d['domain']);
        $d['ssl_days']      = SSLManager::daysUntilExpiry($d['domain']);
    }
    ok('ok', ['domains' => $doms]);

case 'domain_add':
    $domain  = strtolower(preg_replace('/[^a-z0-9.\-]/', '', sp('domain')));
    $type    = in_array(sp('type'),['addon','subdomain','parked']) ? sp('type') : 'addon';
    $phpVer  = preg_replace('/[^0-9.]/',  '', sp('php_version')) ?: PHP_VER;

    if (empty($domain)) err('Domain name is required');
    if (!preg_match('/^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/', $domain))
        err("Invalid domain name: $domain");
    if (DB::one("SELECT id FROM user_domains WHERE domain=?", [$domain])) err("Domain '$domain' already exists on this server");

    // Ensure user's FPM pool exists (creates it if missing)
    VHost::ensureFpmPool($me, $phpVer);

    // Determine webroot based on type (cPanel layout)
    if ($type === 'subdomain') {
        $sub     = explode('.', $domain)[0];
        $webroot = "/home/$me/public_html/subdomains/$sub";
    } elseif ($type === 'parked') {
        $webroot = "/home/$me/public_html"; // same root as primary
    } else {
        $webroot = "/home/$me/public_html/addons/$domain";
    }

    $res = VHost::create($me, $domain, $webroot, $phpVer, $type);
    if (!$res['ok']) err($res['msg']);

    DB::exec(
        "INSERT INTO user_domains (user_id, username, domain, type, webroot, php_version) VALUES (?,?,?,?,?,?)",
        [$myUid, $me, $domain, $type, $webroot, $phpVer]
    );
    Auth::log('domain_add', "$type:$domain → $webroot");
    ok("Domain '$domain' added", ['webroot' => $webroot]);

case 'domain_delete':
    $row = DB::one("SELECT * FROM user_domains WHERE id=? AND username=?", [ip('id'), $me]);
    if (!$row) err('Domain not found');
    if ($row['type'] === 'main') err('Cannot delete the primary domain. Delete the whole account to remove it.');
    VHost::delete($row['domain']);
    if ($row['ssl_enabled']) SSLManager::revoke($row['domain']);
    DB::exec("DELETE FROM user_domains WHERE id=?", [ip('id')]);
    Auth::log('domain_delete', $row['domain']);
    ok("Domain {$row['domain']} removed");

case 'domain_ssl':
    $row = DB::one("SELECT * FROM user_domains WHERE id=? AND username=?", [ip('id'), $me]);
    if (!$row) err('Domain not found');
    $email = filter_var(sp('email'), FILTER_VALIDATE_EMAIL) ?: "$me@{$row['domain']}";
    $r = SSLManager::issue($row['domain'], $email);
    if ($r['ok']) {
        $exp = SSLManager::expiry($row['domain']);
        DB::exec("UPDATE user_domains SET ssl_enabled=1, ssl_expiry=? WHERE id=?", [$exp, ip('id')]);
        Auth::log('ssl_issue', $row['domain']);
    }
    ok($r['ok'] ? '✓ SSL certificate issued successfully' : 'SSL failed: check domain DNS is pointing to this server',
       ['detail' => $r['output'], 'success' => $r['ok']]);

// ── Databases ─────────────────────────────────────────────────────────────────
case 'dbs_list':
    ok('ok', ['dbs' => DBManager::listForUser($me)]);

case 'db_create':
    $pass = sp('db_pass') ?: bin2hex(random_bytes(10));
    $r = DBManager::createDB($me, sp('db_name'), sp('db_user'), $pass);
    $r['ok']
        ? ok($r['msg'], ['db_name'=>$r['db_name'],'db_user'=>$r['db_user'],'db_pass'=>$r['db_pass']])
        : err($r['msg']);

case 'db_drop':
    $r = DBManager::dropDB(ip('id'), $me);
    $r['ok'] ? ok($r['msg']) : err($r['msg']);

// ── File Manager ──────────────────────────────────────────────────────────────
case 'fm_ls':
    try { ok('ok', ['items' => $fm->ls(sp('path')), 'path' => sp('path')]); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_read':
    try { ok('ok', ['content' => $fm->read(sp('path'))]); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_write':
    try { $fm->write(sp('path'), $data['content'] ?? ''); ok('File saved'); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_mkdir':
    try { $fm->mkdir(sp('path')); ok('Directory created'); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_delete':
    try { $fm->delete(sp('path')); ok('Deleted'); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_rename':
    try { $fm->rename(sp('from'), sp('to')); ok('Renamed'); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_chmod':
    try { $fm->chmod(sp('path'), sp('mode')); ok('Permissions updated'); }
    catch (RuntimeException $e) { err($e->getMessage()); }

case 'fm_upload':
    try {
        if (empty($_FILES['file'])) err('No file uploaded');
        $fm->upload(sp('dest') ?: '/', $_FILES['file']);
        ok('File uploaded: ' . basename($_FILES['file']['name']));
    } catch (RuntimeException $e) { err($e->getMessage()); }

// ── Cron ──────────────────────────────────────────────────────────────────────
case 'cron_list':
    ok('ok', ['jobs' => CronManager::listForUser($me)]);

case 'cron_add':
    $r = CronManager::add($myUid, $me, sp('schedule'), sp('command'), sp('label'));
    $r['ok'] ? ok($r['msg']) : err($r['msg']);

case 'cron_delete':
    $r = CronManager::delete(ip('id'), $me);
    $r['ok'] ? ok($r['msg']) : err($r['msg']);

case 'cron_toggle':
    CronManager::toggle(ip('id'), $me) ? ok('Toggled') : err('Not found');

// ── Backups ───────────────────────────────────────────────────────────────────
case 'backup_list':
    ok('ok', ['backups' => BackupManager::listBackups($me)]);

case 'backup_create':
    // Backups can take time — run in background
    $r = BackupManager::runBackup($myUid, $me);
    $r['ok'] ? ok($r['msg']) : err($r['msg']);

case 'backup_delete':
    $r = BackupManager::deleteBackup(ip('id'), $me);
    $r['ok'] ? ok($r['msg']) : err($r['msg']);

// ── SSH Keys ──────────────────────────────────────────────────────────────────
case 'ssh_add_key':
    $r = SysUser::addSshKey($me, sp('pubkey'));
    $r['ok'] ? ok($r['msg']) : err($r['msg']);

case 'ssh_list_keys':
    $akFile = "/home/$me/.ssh/authorized_keys";
    $keys   = file_exists($akFile) ? array_filter(file($akFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES), fn($l) => !str_starts_with($l,'#')) : [];
    ok('ok', ['keys' => array_values($keys)]);

// ── PHP Info ──────────────────────────────────────────────────────────────────
case 'php_info':
    ok('ok', [
        'version'    => PHP_VERSION,
        'ini'        => php_ini_loaded_file(),
        'extensions' => get_loaded_extensions(),
        'limits'     => [
            'memory'       => ini_get('memory_limit'),
            'exec_time'    => ini_get('max_execution_time') . 's',
            'upload_size'  => ini_get('upload_max_filesize'),
            'post_size'    => ini_get('post_max_size'),
            'open_basedir' => ini_get('open_basedir'),
        ],
    ]);

// ── Change Password ───────────────────────────────────────────────────────────
case 'change_password':
    $old = sp('old_pass');
    $new = sp('new_pass');
    if (strlen($new) < 8) err('New password must be at least 8 characters');
    $row = DB::one("SELECT password_hash FROM panel_users WHERE id=?", [$myUid]);
    if (!password_verify($old, $row['password_hash'])) err('Current password is incorrect');
    SysUser::setPassword($me, $new);
    $hash = password_hash($new, PASSWORD_BCRYPT, ['cost' => 12]);
    DB::exec("UPDATE panel_users SET password_hash=? WHERE id=?", [$hash, $myUid]);
    Auth::log('password_change', 'self');
    ok('Password updated — use new password on next login');

default:
    err("Unknown API: '$action'");
}
PHPEOF

log "User API written"

# ── User Panel HTML ───────────────────────────────────────────────────────────
cat > "${PANEL_DIR}/user/public/tpl_panel.php" << 'HTML'
<?php $me = Auth::user(); $suAdmin = !empty($_SESSION['su_admin']); ?>
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WebPanel — <?=htmlspecialchars($me)?></title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Outfit:wght@300;400;600;800&display=swap" rel="stylesheet">
<style>
:root{--bg:#06020f;--surf:#0d0820;--surf2:#110c28;--brd:#1a1038;--acc:#9b73ff;--acc2:#4fa8ff;--acc3:#2ee89e;--danger:#ff6b88;--warn:#fbbf24;--ok:#2ee89e;--text:#ede8ff;--muted:#6a5a8a;--muted2:#2c1e50;--sidebar:235px;--mono:'JetBrains Mono',monospace;--font:'Outfit',sans-serif}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:var(--font);display:flex;min-height:100vh;font-size:14px}
.sb{width:var(--sidebar);background:var(--surf);border-right:1px solid var(--brd);display:flex;flex-direction:column;position:fixed;height:100vh;overflow-y:auto;z-index:100}
.sb-logo{padding:1.3rem 1.1rem;border-bottom:1px solid var(--brd)}
.sb-logo h1{font-weight:800;font-size:.9rem;background:linear-gradient(135deg,var(--acc),var(--acc2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:.05em}
.sb-uname{font-family:var(--mono);font-size:.68rem;color:var(--muted);margin-top:.2rem}
.ng{padding:.7rem .7rem .15rem;font-size:.58rem;color:var(--muted2);letter-spacing:.18em;text-transform:uppercase;font-family:var(--mono)}
nav a{display:flex;align-items:center;gap:.6rem;padding:.55rem .9rem;color:var(--muted);text-decoration:none;font-size:.78rem;transition:.15s;border-left:2px solid transparent;margin:.08rem .4rem;border-radius:0 8px 8px 0}
nav a .ic{font-size:.82rem;width:15px;text-align:center}
nav a:hover{color:var(--text);background:rgba(155,115,255,.07)}
nav a.on{color:var(--acc);background:rgba(155,115,255,.1);border-left-color:var(--acc);font-weight:600}
.sb-foot{margin-top:auto;padding:.9rem;border-top:1px solid var(--brd);font-size:.75rem}
.sb-foot strong{color:var(--text);display:block;margin-bottom:.2rem}
.sb-foot a{color:var(--muted);text-decoration:none;display:block;margin-top:.25rem}
.sb-foot a:hover{color:var(--danger)}
.su-banner{background:rgba(251,191,36,.08);border-top:1px solid rgba(251,191,36,.2);padding:.5rem .9rem;font-size:.7rem;color:var(--warn);font-family:var(--mono)}
.main{margin-left:var(--sidebar);flex:1;min-width:0}
.topbar{background:var(--surf);border-bottom:1px solid var(--brd);padding:.62rem 1.5rem;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:50}
.topbar h2{font-size:.76rem;font-family:var(--mono);color:var(--muted);letter-spacing:.1em;text-transform:uppercase}
#uclock{font-family:var(--mono);font-size:.72rem;color:var(--muted)}
.content{padding:1.3rem 1.5rem}
.sec{display:none}.sec.on{display:block}
.sh{display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:1.3rem;gap:1rem;flex-wrap:wrap}
.sh h2{font-size:1.1rem;font-weight:800}.sh p{color:var(--muted);font-size:.76rem;margin-top:.12rem}
.card{background:var(--surf);border:1px solid var(--brd);border-radius:13px;padding:1.1rem;margin-bottom:.9rem}
.ct{font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.14em;font-family:var(--mono);margin-bottom:.7rem}
.sg{display:grid;grid-template-columns:repeat(4,1fr);gap:.8rem;margin-bottom:1rem}
.sc{background:var(--surf);border:1px solid var(--brd);border-radius:12px;padding:1rem 1.1rem;position:relative;overflow:hidden}
.sc::after{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:var(--sc,var(--acc))}
.sl{font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);margin-bottom:.35rem}
.sv{font-size:1.6rem;font-weight:800;line-height:1}.ss{font-size:.66rem;color:var(--muted);margin-top:.2rem}
.db{background:var(--brd);border-radius:3px;height:4px;overflow:hidden;margin-top:.2rem}
.dbf{height:100%;border-radius:3px;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .5s}
.b{display:inline-flex;align-items:center;padding:.13rem .45rem;border-radius:20px;font-size:.58rem;font-weight:700;letter-spacing:.04em;font-family:var(--mono);white-space:nowrap}
.bg{background:rgba(46,232,158,.1);color:var(--ok);border:1px solid rgba(46,232,158,.2)}
.br{background:rgba(255,107,136,.1);color:var(--danger);border:1px solid rgba(255,107,136,.2)}
.bb{background:rgba(79,168,255,.1);color:var(--acc2);border:1px solid rgba(79,168,255,.2)}
.bp{background:rgba(155,115,255,.1);color:var(--acc);border:1px solid rgba(155,115,255,.2)}
.bo{background:rgba(251,191,36,.1);color:var(--warn);border:1px solid rgba(251,191,36,.2)}
.btn{display:inline-flex;align-items:center;gap:.3rem;padding:.38rem .9rem;border:none;border-radius:8px;cursor:pointer;font-family:var(--font);font-size:.74rem;font-weight:600;transition:.15s;text-decoration:none;white-space:nowrap}
.btp{background:linear-gradient(135deg,var(--acc),#7451d4);color:#06020f}
.btp:hover{box-shadow:0 4px 14px rgba(155,115,255,.3)}
.btb{background:linear-gradient(135deg,var(--acc2),#3072c4);color:#06020f}
.btd{background:rgba(255,107,136,.12);color:var(--danger);border:1px solid rgba(255,107,136,.25)}
.btd:hover{background:var(--danger);color:#fff}
.btw{background:rgba(251,191,36,.12);color:var(--warn);border:1px solid rgba(251,191,36,.25)}
.bts{background:rgba(46,232,158,.12);color:var(--ok);border:1px solid rgba(46,232,158,.25)}
.btg{background:rgba(255,255,255,.04);color:var(--muted);border:1px solid var(--brd)}
.btg:hover{color:var(--text);background:rgba(255,255,255,.07)}
.sm{padding:.27rem .65rem;font-size:.7rem}.xs{padding:.16rem .45rem;font-size:.6rem}
.tw{overflow-x:auto;border-radius:11px;border:1px solid var(--brd)}
table{width:100%;border-collapse:collapse;font-size:.78rem}
thead{background:var(--surf2)}
th{padding:.6rem .85rem;text-align:left;font-size:.58rem;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);border-bottom:1px solid var(--brd);white-space:nowrap}
td{padding:.55rem .85rem;border-bottom:1px solid rgba(26,16,56,.5);vertical-align:middle}
tr:last-child td{border:none}
tr:hover td{background:rgba(155,115,255,.03)}
.fg{display:grid;gap:.75rem;margin-bottom:.8rem}
.fg2{grid-template-columns:1fr 1fr}.fg3{grid-template-columns:1fr 1fr 1fr}
.fg label{display:block;color:var(--muted);font-size:.58rem;text-transform:uppercase;letter-spacing:.1em;font-family:var(--mono);margin-bottom:.32rem}
.fg input,.fg select,.fg textarea{width:100%;background:rgba(155,115,255,.04);border:1px solid var(--brd);border-radius:8px;padding:.52rem .82rem;color:var(--text);font-family:var(--font);font-size:.82rem;transition:.2s}
.fg input:focus,.fg select:focus,.fg textarea:focus{outline:none;border-color:var(--acc);background:rgba(155,115,255,.08)}
.fg select option{background:var(--surf)}
.fhint{font-size:.62rem;color:var(--muted);margin-top:.22rem}
.al{padding:.58rem .9rem;border-radius:9px;margin-bottom:.7rem;font-size:.78rem;display:none}
.aok{background:rgba(46,232,158,.08);border:1px solid rgba(46,232,158,.2);color:var(--ok)}
.aerr{background:rgba(255,107,136,.08);border:1px solid rgba(255,107,136,.2);color:var(--danger)}
.mo{display:none;position:fixed;inset:0;background:rgba(0,0,0,.82);z-index:999;align-items:center;justify-content:center;backdrop-filter:blur(4px)}
.mo.on{display:flex}
.mob{background:var(--surf);border:1px solid var(--brd);border-radius:16px;padding:1.6rem;width:min(500px,94vw);max-height:88vh;overflow-y:auto;box-shadow:0 40px 80px rgba(0,0,0,.5)}
.mob h3{font-size:.9rem;margin-bottom:1rem}
.mof{display:flex;gap:.45rem;justify-content:flex-end;margin-top:1rem;padding-top:.85rem;border-top:1px solid var(--brd)}
/* File Manager */
.fm-bar{display:flex;gap:.35rem;margin-bottom:.5rem;flex-wrap:wrap;align-items:center}
.fm-path{font-family:var(--mono);font-size:.72rem;color:var(--acc);background:rgba(155,115,255,.06);border:1px solid var(--brd);border-radius:6px;padding:.28rem .65rem;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-icon{font-size:.85rem;margin-right:.25rem}
.fm-name{cursor:pointer;transition:color .15s}
.fm-name:hover,.fm-name:focus{color:var(--acc);text-decoration:underline}
.fm-dir{font-weight:600;color:var(--acc2)}
.editor{background:#03000a;border:1px solid var(--brd);border-radius:8px;font-family:var(--mono);font-size:.74rem;color:#d8ccff;width:100%;height:420px;padding:.75rem;resize:vertical;line-height:1.65;tab-size:2;outline:none}
.editor:focus{border-color:var(--acc)}
/* Cron presets */
.presets{display:flex;gap:.28rem;flex-wrap:wrap;margin-bottom:.55rem}
.preset{padding:.2rem .55rem;background:rgba(155,115,255,.08);border:1px solid rgba(155,115,255,.18);border-radius:20px;font-size:.62rem;font-family:var(--mono);color:var(--acc);cursor:pointer;transition:.15s}
.preset:hover{background:rgba(155,115,255,.16)}
/* Info box */
.ibox{background:var(--surf2);border:1px solid var(--brd);border-radius:10px;padding:.85rem 1rem}
.irow{display:flex;justify-content:space-between;align-items:center;padding:.3rem 0;border-bottom:1px solid rgba(26,16,56,.6);font-size:.78rem}
.irow:last-child{border:none}
.ik{color:var(--muted);font-family:var(--mono);font-size:.65rem}
.iv{color:var(--text);font-family:var(--mono);font-size:.72rem}
</style>
</head><body>

<aside class="sb">
  <div class="sb-logo">
    <h1>🌐 WEBPANEL</h1>
    <div class="sb-uname">/home/<?=htmlspecialchars($me)?>/</div>
  </div>
  <div class="ng">Hosting</div>
  <nav>
    <a href="#" class="on" data-s="overview"><span class="ic">📊</span>Overview</a>
    <a href="#" data-s="domains"><span class="ic">🌐</span>Domains & SSL</a>
    <a href="#" data-s="files"><span class="ic">📁</span>File Manager</a>
    <a href="#" data-s="databases"><span class="ic">🗄</span>Databases</a>
    <a href="#" data-s="cron"><span class="ic">⏱</span>Cron Jobs</a>
    <a href="#" data-s="backups"><span class="ic">🗜</span>Backups</a>
    <a href="#" data-s="ssh"><span class="ic">🔐</span>SSH Keys</a>
    <div class="ng">Config</div>
    <a href="#" data-s="phpinfo"><span class="ic">🐘</span>PHP Info</a>
    <a href="#" data-s="password"><span class="ic">🔑</span>Change Password</a>
    <a href="/phpmyadmin/" target="_blank"><span class="ic">🗂</span>phpMyAdmin ↗</a>
  </nav>
  <div class="sb-foot">
    <strong><?=htmlspecialchars($me)?></strong>
    <a href="?page=logout">Sign Out →</a>
  </div>
  <?php if($suAdmin): ?>
  <div class="su-banner">⚠ Viewing as admin · <a href="//<?=$_SERVER['HTTP_HOST']?>:<?=ADMIN_PORT?>/" style="color:var(--warn)">Back to Admin →</a></div>
  <?php endif; ?>
</aside>

<div class="main">
<div class="topbar">
  <h2 id="ptitle">OVERVIEW</h2>
  <span id="uclock"></span>
</div>
<div class="content">

<!-- OVERVIEW -->
<div id="s-overview" class="sec on">
  <div class="sg">
    <div class="sc" style="--sc:var(--acc)"><div class="sl">Disk Used</div><div class="sv" id="ov-disk">—</div><div class="ss" id="ov-dpct">—</div><div class="db" style="margin-top:.5rem"><div class="dbf" id="ov-dbar" style="width:0%"></div></div></div>
    <div class="sc" style="--sc:var(--acc2)"><div class="sl">Domains</div><div class="sv" id="ov-doms">—</div><div class="ss">active domains</div></div>
    <div class="sc" style="--sc:var(--acc3)"><div class="sl">Databases</div><div class="sv" id="ov-dbs">—</div><div class="ss">MariaDB databases</div></div>
    <div class="sc" style="--sc:var(--warn)"><div class="sl">Cron Jobs</div><div class="sv" id="ov-cron">—</div><div class="ss">scheduled tasks</div></div>
  </div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:.9rem">
    <div class="card">
      <div class="ct">🏠 YOUR HOME DIRECTORY</div>
      <div class="ibox">
        <div class="irow"><span class="ik">Home</span><span class="iv">/home/<?=htmlspecialchars($me)?>/</span></div>
        <div class="irow"><span class="ik">Web Root</span><span class="iv">~/public_html/</span></div>
        <div class="irow"><span class="ik">Subdomains</span><span class="iv">~/public_html/subdomains/</span></div>
        <div class="irow"><span class="ik">Addon Domains</span><span class="iv">~/public_html/addons/</span></div>
        <div class="irow"><span class="ik">Logs</span><span class="iv">~/logs/</span></div>
        <div class="irow"><span class="ik">Cron</span><span class="iv">system crontab (user)</span></div>
        <div class="irow"><span class="ik">PHP Pool</span><span class="iv">isolated FPM socket</span></div>
        <div class="irow"><span class="ik">PHP open_basedir</span><span class="iv">/home/<?=htmlspecialchars($me)?>/ only</span></div>
      </div>
    </div>
    <div class="card">
      <div class="ct">🔗 CONNECTION INFO</div>
      <div class="ibox">
        <div class="irow"><span class="ik">SFTP Host</span><span class="iv" id="ov-host">—</span></div>
        <div class="irow"><span class="ik">SFTP Port</span><span class="iv">22</span></div>
        <div class="irow"><span class="ik">SFTP Root</span><span class="iv">/home/<?=htmlspecialchars($me)?>/</span></div>
        <div class="irow"><span class="ik">FTP Port</span><span class="iv">21 (passive)</span></div>
        <div class="irow"><span class="ik">Username</span><span class="iv"><?=htmlspecialchars($me)?></span></div>
        <div class="irow"><span class="ik">PHP Version</span><span class="iv" id="ov-php">—</span></div>
        <div class="irow"><span class="ik">Account Created</span><span class="iv" id="ov-created">—</span></div>
      </div>
    </div>
  </div>
</div>

<!-- DOMAINS & SSL -->
<div id="s-domains" class="sec">
  <div class="sh"><div><h2>Domains & SSL</h2><p>Addon domains, subdomains and Let's Encrypt SSL certificates</p></div>
    <button class="btn btp" onclick="smo('mo-adddomain')">+ Add Domain</button></div>
  <div id="al-domains" class="al"></div>
  <div class="tw"><table><thead><tr>
    <th>Domain</th><th>Type</th><th>Web Root</th><th>PHP</th><th>SSL</th><th>Apache</th><th>Actions</th>
  </tr></thead><tbody id="dom-tbody"></tbody></table></div>
  <div class="card" style="margin-top:1rem">
    <div class="ct">ℹ PRIMARY DOMAIN</div>
    <p style="font-size:.8rem;color:var(--muted);line-height:1.7">Your <strong style="color:var(--text)">primary domain</strong> was set up during account creation. Its web root is <code style="color:var(--acc)">~/public_html/</code>. Addon domains go to <code style="color:var(--acc)">~/public_html/addons/{domain}/</code> and subdomains to <code style="color:var(--acc)">~/public_html/subdomains/{name}/</code>. Add those directories via the File Manager or upload via FTP/SFTP.</p>
  </div>
</div>

<!-- FILE MANAGER -->
<div id="s-files" class="sec">
  <div class="sh"><div><h2>File Manager</h2><p>Browse and edit files in /home/<?=htmlspecialchars($me)?>/</p></div></div>
  <div class="card" style="padding:.75rem">
    <div class="fm-bar">
      <button class="btn xs btg" onclick="fm_up()">⬆ Up</button>
      <span class="fm-path" id="fm-cwd">/</span>
      <button class="btn xs btp" onclick="smo('mo-mkdir')">📁 New Folder</button>
      <button class="btn xs btg" onclick="smo('mo-upload')">⬆ Upload</button>
      <button class="btn xs btg" onclick="fm_load(fm_cur)">↻</button>
    </div>
    <div class="tw">
      <table><thead><tr><th>Name</th><th>Type</th><th>Size</th><th>Perms</th><th>Modified</th><th>Actions</th></tr></thead>
      <tbody id="fm-tbody"><tr><td colspan="6" style="text-align:center;color:var(--muted);padding:2rem">Loading…</td></tr></tbody></table>
    </div>
    <div id="al-fm" class="al" style="margin-top:.5rem"></div>
  </div>
</div>

<!-- DATABASES -->
<div id="s-databases" class="sec">
  <div class="sh"><div><h2>Databases</h2><p>MariaDB — all DB names and users are prefixed <code style="color:var(--acc)"><?=htmlspecialchars($me)?>_</code></p></div>
    <button class="btn btp" onclick="smo('mo-newdb')">+ Create DB</button></div>
  <div id="al-dbs" class="al"></div>
  <div class="tw"><table><thead><tr>
    <th>Database Name</th><th>DB Username</th><th>Created</th><th>Actions</th>
  </tr></thead><tbody id="dbs-tbody"></tbody></table></div>
</div>

<!-- CRON JOBS -->
<div id="s-cron" class="sec">
  <div class="sh"><div><h2>Cron Jobs</h2><p>Scheduled tasks running as system user <code style="color:var(--acc)"><?=htmlspecialchars($me)?></code></p></div>
    <button class="btn btp" onclick="smo('mo-addcron')">+ Add Cron</button></div>
  <div id="al-cron" class="al"></div>
  <div class="tw"><table><thead><tr>
    <th>Label</th><th>Schedule</th><th>Command</th><th>Status</th><th>Actions</th>
  </tr></thead><tbody id="cron-tbody"></tbody></table></div>
</div>

<!-- BACKUPS -->
<div id="s-backups" class="sec">
  <div class="sh">
    <div><h2>Backups</h2><p>Full backups of your home directory + all databases (stored in ~/backups/)</p></div>
    <button class="btn btp" onclick="createBackup()">🗜 Create Backup Now</button>
  </div>
  <div id="al-backups" class="al"></div>
  <div class="tw"><table><thead><tr>
    <th>Filename</th><th>Size</th><th>Type</th><th>Status</th><th>Created</th><th>Actions</th>
  </tr></thead><tbody id="bk-tbody"></tbody></table></div>
</div>

<!-- SSH KEYS -->
<div id="s-ssh" class="sec">
  <div class="sh"><div><h2>SSH Keys</h2><p>Paste your public key to enable key-based SSH/SFTP login</p></div></div>
  <div id="al-ssh" class="al"></div>
  <div class="card" style="max-width:640px">
    <div class="ct">ADD PUBLIC KEY</div>
    <div class="fg"><div><label>Public Key (ssh-rsa / ssh-ed25519 / ecdsa)</label>
      <textarea id="ssh-key" rows="4" style="width:100%;background:rgba(155,115,255,.04);border:1px solid var(--brd);border-radius:8px;padding:.6rem .85rem;color:var(--text);font-family:var(--mono);font-size:.72rem;resize:vertical" placeholder="ssh-ed25519 AAAA... user@host"></textarea></div></div>
    <button class="btn btp sm" onclick="addSSHKey()">Add Key</button>
  </div>
  <div class="card" style="margin-top:.9rem">
    <div class="ct">AUTHORIZED KEYS</div>
    <div id="ssh-list" style="font-family:var(--mono);font-size:.7rem;color:var(--muted)">Loading…</div>
  </div>
</div>

<!-- PHP INFO -->
<div id="s-phpinfo" class="sec">
  <div class="sh"><div><h2>PHP Information</h2></div></div>
  <div class="card" style="padding:0;overflow:hidden">
    <iframe src="?page=phpinfo" style="width:100%;height:72vh;border:none;background:#fff" title="PHP Info"></iframe>
  </div>
</div>

<!-- CHANGE PASSWORD -->
<div id="s-password" class="sec">
  <div class="sh"><div><h2>Change Password</h2><p>Updates both panel login and system (FTP/SFTP/SSH) password</p></div></div>
  <div class="card" style="max-width:400px">
    <div id="al-chpass" class="al"></div>
    <div class="fg">
      <div><label>Current Password</label><input type="password" id="cp-old"></div>
      <div><label>New Password</label><input type="password" id="cp-new"></div>
      <div><label>Confirm New Password</label><input type="password" id="cp-new2"></div>
    </div>
    <button class="btn btp" onclick="changePassword()">Update Password</button>
  </div>
</div>

</div><!-- .content -->
</div><!-- .main -->

<!-- MODALS -->
<div class="mo" id="mo-adddomain">
  <div class="mob">
    <h3>🌐 Add Domain</h3>
    <div id="al-mo-dom" class="al"></div>
    <div class="fg">
      <div><label>Domain Name *</label><input id="ad-dom" placeholder="sub.example.com or addon.com">
        <div class="fhint">For subdomains: sub.yourdomain.com → root: ~/public_html/subdomains/sub/<br>For addon domains: anotherdomain.com → root: ~/public_html/addons/anotherdomain.com/</div></div>
    </div>
    <div class="fg fg2">
      <div><label>Type</label>
        <select id="ad-type">
          <option value="addon">Addon Domain (separate root)</option>
          <option value="subdomain">Subdomain</option>
          <option value="parked">Parked (same root)</option>
        </select></div>
      <div><label>PHP Version</label>
        <select id="ad-php">
          <option value="8.4">PHP 8.4 (recommended)</option>
          <option value="8.3">PHP 8.3</option>
          <option value="8.2">PHP 8.2</option>
          <option value="8.1">PHP 8.1</option>
        </select></div>
    </div>
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-adddomain')">Cancel</button>
      <button class="btn btp" onclick="addDomain()">Add Domain →</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-ssl">
  <div class="mob">
    <h3>🔒 Issue Let's Encrypt SSL</h3>
    <div class="fg">
      <div><label>Domain</label><input id="ssl-dom" readonly style="opacity:.65"></div>
      <div><label>Notification Email *</label><input id="ssl-em" type="email" placeholder="you@yourdomain.com"><div class="fhint">DNS A record must point to this server's IP first.</div></div>
    </div>
    <input type="hidden" id="ssl-id">
    <div id="ssl-out" class="editor" style="height:110px;display:none;font-size:.68rem;color:#2ee89e;padding:.6rem;white-space:pre-wrap"></div>
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-ssl')">Cancel</button>
      <button class="btn btp" id="ssl-btn" onclick="issueSSL()">Issue SSL Certificate →</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-newdb">
  <div class="mob">
    <h3>🗄 Create Database</h3>
    <div id="al-mo-db" class="al"></div>
    <div class="fg fg3">
      <div><label>DB Name Suffix *</label><input id="db-n" placeholder="myapp" oninput="dbprev()"><div class="fhint">Full: <code id="db-np" style="color:var(--acc)"><?=htmlspecialchars($me)?>_myapp</code></div></div>
      <div><label>DB User Suffix *</label><input id="db-u" placeholder="user" oninput="dbprev()"><div class="fhint">Full: <code id="db-up" style="color:var(--acc)"><?=htmlspecialchars($me)?>_user</code></div></div>
      <div><label>Password</label><input id="db-p" placeholder="auto-generated"><button class="btn xs btg" style="margin-top:.3rem" onclick="gendbp()">⚡ Gen</button></div>
    </div>
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-newdb')">Cancel</button>
      <button class="btn btp" onclick="createDB()">Create →</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-addcron">
  <div class="mob">
    <h3>⏱ Add Cron Job</h3>
    <div id="al-mo-cron" class="al"></div>
    <div class="fg"><div><label>Label (optional)</label><input id="cr-l" placeholder="Daily cleanup, Cache clear…"></div></div>
    <div class="ct">SCHEDULE PRESETS</div>
    <div class="presets">
      <span class="preset" onclick="cpreset('* * * * *')">Every minute</span>
      <span class="preset" onclick="cpreset('*/5 * * * *')">Every 5 min</span>
      <span class="preset" onclick="cpreset('*/15 * * * *')">Every 15 min</span>
      <span class="preset" onclick="cpreset('0 * * * *')">Hourly</span>
      <span class="preset" onclick="cpreset('0 0 * * *')">Daily midnight</span>
      <span class="preset" onclick="cpreset('0 8 * * 1-5')">Weekdays 8am</span>
      <span class="preset" onclick="cpreset('0 0 * * 0')">Weekly Sunday</span>
      <span class="preset" onclick="cpreset('0 0 1 * *')">Monthly 1st</span>
    </div>
    <div class="fg fg2">
      <div><label>Schedule (min hr dom mon dow)</label><input id="cr-s" placeholder="0 * * * *" style="font-family:var(--mono)"></div>
      <div><label>Command *</label><input id="cr-c" placeholder="/usr/bin/php ~/public_html/cron.php"></div>
    </div>
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-addcron')">Cancel</button>
      <button class="btn btp" onclick="addCron()">Add Cron Job →</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-mkdir">
  <div class="mob" style="width:360px">
    <h3>📁 New Folder</h3>
    <div class="fg"><div><label>Folder Name</label><input id="dir-n" placeholder="new-folder" autofocus></div></div>
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-mkdir')">Cancel</button>
      <button class="btn btp" onclick="fm_mkdir()">Create</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-upload">
  <div class="mob" style="width:380px">
    <h3>⬆ Upload File</h3>
    <div id="al-up" class="al"></div>
    <div class="fg"><div><label>Select File</label><input type="file" id="up-f" multiple></div></div>
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-upload')">Cancel</button>
      <button class="btn btp" onclick="fm_upload()">Upload</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-editor">
  <div class="mob" style="width:min(820px,96vw)">
    <h3>✏️ <span id="ed-fn" style="font-family:var(--mono);font-size:.82rem;color:var(--acc)"></span></h3>
    <textarea class="editor" id="ed-txt"></textarea>
    <input type="hidden" id="ed-path">
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-editor')">Cancel</button>
      <button class="btn btp" onclick="fm_save()">💾 Save</button>
    </div>
  </div>
</div>

<div class="mo" id="mo-chmod">
  <div class="mob" style="width:340px">
    <h3>🔒 Change Permissions</h3>
    <div class="fg"><div><label>Octal Mode (e.g. 755, 644)</label><input id="ch-mode" placeholder="755" maxlength="4"></div></div>
    <input type="hidden" id="ch-path">
    <div class="mof">
      <button class="btn btg" onclick="hmo('mo-chmod')">Cancel</button>
      <button class="btn btp" onclick="fm_chmod()">Apply</button>
    </div>
  </div>
</div>

<script>
const ME = '<?=htmlspecialchars($me)?>';
const api = (a,d={}) => fetch('?api='+a,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).catch(e=>({ok:false,msg:e.message}));
const $ = id => document.getElementById(id);
const rp = (n=16) => [...crypto.getRandomValues(new Uint8Array(n))].map(b=>'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%'[b%58]).join('');
const badge = (t,c) => `<span class="b ${c}">${t}</span>`;

// Nav
const SM = {overview:loadOv,domains:loadDomains,files:loadFiles,databases:loadDBs,cron:loadCron,backups:loadBackups,ssh:loadSSH,phpinfo:()=>{},password:()=>{}};
function nav(s){
  document.querySelectorAll('.sec').forEach(e=>e.classList.remove('on'));
  document.querySelectorAll('nav a[data-s]').forEach(e=>e.classList.remove('on'));
  $('s-'+s)?.classList.add('on');
  document.querySelector(`nav a[data-s="${s}"]`)?.classList.add('on');
  $('ptitle').textContent=s.toUpperCase().replace('-',' ');
  SM[s]?.();
}
document.querySelectorAll('nav a[data-s]').forEach(a=>a.addEventListener('click',e=>{e.preventDefault();nav(a.dataset.s)}));
function smo(id){$(id).classList.add('on')}
function hmo(id){$(id).classList.remove('on')}
document.querySelectorAll('.mo').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('on')}));
function al(id,msg,ok){const e=$(id);e.className='al '+(ok?'aok':'aerr');e.textContent=msg;e.style.display='block';setTimeout(()=>e.style.display='none',8000)}

// ── Overview ──────────────────────────────────────────────────────────────────
async function loadOv(){
  const r=await api('my_info');
  if(!r.ok) return;
  $('ov-disk').textContent=r.disk_used+' MB';
  $('ov-dpct').textContent=r.disk_pct+'% of '+(r.user?.disk_quota_mb||'?')+' MB quota';
  $('ov-dbar').style.width=Math.min(100,r.disk_pct)+'%';
  $('ov-doms').textContent=r.domains;
  $('ov-dbs').textContent=r.dbs;
  $('ov-cron').textContent=r.crons;
  $('ov-host').textContent=r.hostname||location.hostname;
  $('ov-php').textContent='PHP '+r.php_ver;
  $('ov-created').textContent=r.user?.created_at?.substring(0,10)||'—';
}

// ── Domains ───────────────────────────────────────────────────────────────────
async function loadDomains(){
  const r=await api('domains_list');
  const ds=r.domains||[];
  $('dom-tbody').innerHTML=ds.length?ds.map(d=>`<tr>
    <td><strong>${d.domain}</strong></td>
    <td>${badge(d.type,'bp')}</td>
    <td style="font-size:.68rem;color:var(--muted);font-family:var(--mono);max-width:180px;overflow:hidden;text-overflow:ellipsis">${d.webroot.replace('/home/'+ME,'~')}</td>
    <td>${badge('PHP '+d.php_version,'bo')}</td>
    <td>${d.ssl_enabled=='1'
      ?badge('SSL ✓','bg')+(d.ssl_days!==null?` <span style="font-size:.58rem;color:var(--muted)">${d.ssl_days}d</span>`:'')
      :`<button class="btn xs btw" onclick="openSSL(${d.id},'${d.domain}')">Get SSL</button>`}</td>
    <td>${badge(d.apache_status||'?',d.apache_status==='enabled'?'bg':'br')}</td>
    <td><div style="display:flex;gap:.25rem">
      <a href="http://${d.domain}" target="_blank" class="btn xs btg">Visit ↗</a>
      ${d.type!=='main'?`<button class="btn xs btd" onclick="delDom(${d.id},'${d.domain}')">Delete</button>`:'<span style="font-size:.62rem;color:var(--muted2)">Primary</span>'}
    </div></td>
  </tr>`).join(''):`<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:2rem">No additional domains. Your primary domain serves from <code>~/public_html/</code></td></tr>`;
}
async function addDomain(){
  const r=await api('domain_add',{domain:$('ad-dom').value,type:$('ad-type').value,php_version:$('ad-php').value});
  al('al-mo-dom',r.msg,r.ok);
  if(r.ok){setTimeout(()=>hmo('mo-adddomain'),1500);loadDomains();}
}
async function delDom(id,domain){
  if(!confirm(`Delete domain "${domain}"?\nThe vHost will be removed. Files are NOT deleted.`)) return;
  const r=await api('domain_delete',{id});
  al('al-domains',r.msg,r.ok);loadDomains();
}
function openSSL(id,dom){$('ssl-id').value=id;$('ssl-dom').value=dom;$('ssl-out').style.display='none';$('ssl-btn').disabled=false;smo('mo-ssl')}
async function issueSSL(){
  $('ssl-out').style.display='block';$('ssl-out').textContent='⏳ Running certbot… (30-60 seconds, please wait)';
  $('ssl-btn').disabled=true;
  const r=await api('domain_ssl',{id:$('ssl-id').value,email:$('ssl-em').value});
  $('ssl-out').textContent=r.detail||r.msg;
  $('ssl-btn').disabled=false;
  if(r.success){al('al-domains','SSL certificate issued!',true);setTimeout(()=>hmo('mo-ssl'),2500);loadDomains();}
}

// ── File Manager ──────────────────────────────────────────────────────────────
let fm_cur='/';
async function loadFiles(){fm_load('/');}
async function fm_load(path){
  fm_cur=path;
  $('fm-cwd').textContent='~/'+path.replace(/^\//,'');
  const r=await api('fm_ls',{path});
  if(!r.ok){$('fm-tbody').innerHTML=`<tr><td colspan="6" style="color:var(--danger);padding:1rem">${r.msg}</td></tr>`;return;}
  $('fm-tbody').innerHTML=r.items.map(f=>{
    const isDir=f.type==='dir', isEdit=!isDir&&isEditable(f.name);
    const fp=(path.replace(/\/$/,'')+'/'+f.name).replace('//','/')
    const icon=isDir?'📁':getIcon(f.name);
    return`<tr>
      <td><span class="fm-icon">${icon}</span><span class="${isDir?'fm-name fm-dir':'fm-name'}" onclick="${isDir?`fm_load('${fp.replace(/'/g,"\\'")}')`:isEdit?`fm_edit('${fp.replace(/'/g,"\\'")}','${f.name.replace(/'/g,"\\'")}')`:''}" tabindex="${isDir||isEdit?0:-1}">${f.name}</span>${f.is_link?`<span style="font-size:.6rem;color:var(--muted)"> → ${f.link_to}</span>`:''}</td>
      <td style="font-size:.65rem;color:var(--muted)">${f.type}</td>
      <td style="font-size:.65rem;color:var(--muted)">${isDir?'—':fsize(f.size)}</td>
      <td><code style="font-size:.62rem;color:var(--acc2)">${f.perms}</code></td>
      <td style="font-size:.65rem;color:var(--muted)">${f.modified}</td>
      <td><div style="display:flex;gap:.22rem">
        ${isEdit?`<button class="btn xs btb" onclick="fm_edit('${fp.replace(/'/g,"\\'")}','${f.name.replace(/'/g,"\\'")}')">Edit</button>`:''}
        ${f.name!=='..'?`<button class="btn xs btg" onclick="openChmod('${fp.replace(/'/g,"\\'")}')" title="chmod">🔒</button>
        <button class="btn xs btd" onclick="fm_del('${fp.replace(/'/g,"\\'")}','${f.name.replace(/'/g,"\\'")}')">×</button>`:''}
      </div></td>
    </tr>`;
  }).join('');
}
function fm_up(){const p=fm_cur.replace(/\/[^/]*\/?$/,'')||'/';fm_load(p);}
async function fm_edit(path,name){
  const r=await api('fm_read',{path});
  if(!r.ok){al('al-fm',r.msg,false);return;}
  $('ed-path').value=path;$('ed-fn').textContent=name;$('ed-txt').value=r.content;smo('mo-editor');
}
async function fm_save(){
  const r=await api('fm_write',{path:$('ed-path').value,content:$('ed-txt').value});
  if(r.ok){hmo('mo-editor');al('al-fm','Saved',true);fm_load(fm_cur);}else al('al-fm',r.msg,false);
}
async function fm_mkdir(){
  const n=$('dir-n').value.trim();if(!n)return;
  const r=await api('fm_mkdir',{path:fm_cur.replace(/\/$/,'')+'/'+n});
  if(r.ok){hmo('mo-mkdir');$('dir-n').value='';fm_load(fm_cur);}else al('al-fm',r.msg,false);
}
async function fm_del(path,name){
  if(!confirm(`Delete "${name}"? This cannot be undone.`)) return;
  const r=await api('fm_delete',{path});
  r.ok?fm_load(fm_cur):al('al-fm',r.msg,false);
}
async function fm_upload(){
  const files=$('up-f').files;if(!files.length) return;
  let ok=0,fail=0;
  for(const f of files){
    const fd=new FormData();fd.append('file',f);fd.append('dest',fm_cur);
    const r=await fetch('?api=fm_upload',{method:'POST',body:fd}).then(r=>r.json());
    r.ok?ok++:fail++;
  }
  hmo('mo-upload');
  al('al-fm',`Uploaded ${ok} file(s)${fail?', '+fail+' failed':''}`,fail===0);
  fm_load(fm_cur);
}
function openChmod(path){$('ch-path').value=path;$('ch-mode').value='';smo('mo-chmod');}
async function fm_chmod(){
  const r=await api('fm_chmod',{path:$('ch-path').value,mode:$('ch-mode').value});
  hmo('mo-chmod');al('al-fm',r.msg,r.ok);fm_load(fm_cur);
}
function isEditable(n){return /\.(php|html?|css|js|ts|json|xml|yaml|yml|ini|conf|sh|txt|md|log|htaccess|env|svg)$/i.test(n)}
function getIcon(n){if(/\.(php)$/i.test(n))return'🐘';if(/\.(html?|css|svg)$/i.test(n))return'🌐';if(/\.(js|ts|json)$/i.test(n))return'📜';if(/\.(jpg|jpeg|png|gif|webp)$/i.test(n))return'🖼';if(/\.(zip|tar|gz|bz2|rar)$/i.test(n))return'📦';if(/\.(log|txt|md)$/i.test(n))return'📋';if(/\.(sh|bash)$/i.test(n))return'⚙️';return'📄';}
function fsize(b){if(b<1024)return b+'B';if(b<1048576)return(b/1024).toFixed(1)+'KB';return(b/1048576).toFixed(1)+'MB';}

// ── Databases ─────────────────────────────────────────────────────────────────
async function loadDBs(){
  const r=await api('dbs_list');
  const ds=r.dbs||[];
  $('dbs-tbody').innerHTML=ds.length?ds.map(d=>`<tr>
    <td><strong>${d.db_name}</strong></td>
    <td><code style="font-size:.72rem;color:var(--acc)">${d.db_user}</code></td>
    <td style="font-size:.7rem;color:var(--muted)">${d.created_at?.substring(0,10)}</td>
    <td><button class="btn xs btd" onclick="dropDB(${d.id},'${d.db_name}')">Drop DB</button></td>
  </tr>`).join(''):`<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:2rem">No databases yet</td></tr>`;
}
function dbprev(){$('db-np').textContent=ME+'_'+($('db-n').value||'myapp');$('db-up').textContent=ME+'_'+($('db-u').value||'user');}
function gendbp(){$('db-p').value=rp(16);}
async function createDB(){
  const r=await api('db_create',{db_name:$('db-n').value,db_user:$('db-u').value,db_pass:$('db-p').value||rp()});
  if(r.ok){
    al('al-mo-db',`✓ ${r.msg} | DB: ${r.db_name} | User: ${r.db_user} | Pass: ${r.db_pass}`,true);
    setTimeout(()=>hmo('mo-newdb'),5000);loadDBs();
  }else al('al-mo-db',r.msg,false);
}
async function dropDB(id,name){
  if(!confirm(`DROP database "${name}"?\n\nAll data in this database will be PERMANENTLY deleted.`)) return;
  const r=await api('db_drop',{id});al('al-dbs',r.msg,r.ok);loadDBs();
}

// ── Cron ──────────────────────────────────────────────────────────────────────
async function loadCron(){
  const r=await api('cron_list');
  const js=r.jobs||[];
  $('cron-tbody').innerHTML=js.length?js.map(j=>`<tr>
    <td style="color:var(--muted);font-size:.75rem">${j.label||'—'}</td>
    <td><code style="font-family:var(--mono);font-size:.7rem;color:var(--acc2)">${j.schedule}</code></td>
    <td style="font-family:var(--mono);font-size:.7rem;max-width:220px;overflow:hidden;text-overflow:ellipsis">${j.command}</td>
    <td>${badge(j.enabled=='1'?'Active':'Disabled',j.enabled=='1'?'bg':'br')}</td>
    <td><div style="display:flex;gap:.25rem">
      <button class="btn xs btw" onclick="togCron(${j.id})">${j.enabled=='1'?'Disable':'Enable'}</button>
      <button class="btn xs btd" onclick="delCron(${j.id})">Delete</button>
    </div></td>
  </tr>`).join(''):`<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:2rem">No cron jobs</td></tr>`;
}
function cpreset(v){$('cr-s').value=v;}
async function addCron(){
  const r=await api('cron_add',{schedule:$('cr-s').value,command:$('cr-c').value,label:$('cr-l').value});
  al('al-mo-cron',r.msg,r.ok);
  if(r.ok){setTimeout(()=>hmo('mo-addcron'),1200);loadCron();}
}
async function togCron(id){await api('cron_toggle',{id});loadCron();}
async function delCron(id){if(!confirm('Delete this cron job?')) return;const r=await api('cron_delete',{id});al('al-cron',r.msg,r.ok);loadCron();}

// ── Backups ───────────────────────────────────────────────────────────────────
async function loadBackups(){
  const r=await api('backup_list');
  const bs=r.backups||[];
  $('bk-tbody').innerHTML=bs.length?bs.map(b=>`<tr>
    <td style="font-family:var(--mono);font-size:.72rem">${b.filename}</td>
    <td>${b.size_mb} MB</td>
    <td>${badge(b.type,'bp')}</td>
    <td>${badge(b.status,b.status==='done'?'bg':b.status==='running'?'bo':'br')}</td>
    <td style="font-size:.7rem;color:var(--muted)">${b.created_at?.substring(0,16)}</td>
    <td><button class="btn xs btd" onclick="delBk(${b.id})">Delete</button></td>
  </tr>`).join(''):`<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:2rem">No backups yet</td></tr>`;
}
async function createBackup(){
  al('al-backups','⏳ Creating backup… this may take a minute.',true);
  const r=await api('backup_create');al('al-backups',r.msg,r.ok);loadBackups();
}
async function delBk(id){if(!confirm('Delete this backup?')) return;const r=await api('backup_delete',{id});al('al-backups',r.msg,r.ok);loadBackups();}

// ── SSH Keys ──────────────────────────────────────────────────────────────────
async function loadSSH(){
  const r=await api('ssh_list_keys');
  const keys=r.keys||[];
  $('ssh-list').innerHTML=keys.length
    ?keys.map(k=>`<div style="margin:.3rem 0;padding:.5rem .75rem;background:var(--surf2);border-radius:6px;word-break:break-all;line-height:1.5">${k}</div>`).join('')
    :'<span style="color:var(--muted)">No SSH keys added yet.</span>';
}
async function addSSHKey(){
  const r=await api('ssh_add_key',{pubkey:$('ssh-key').value.trim()});
  al('al-ssh',r.msg,r.ok);if(r.ok){$('ssh-key').value='';loadSSH();}
}

// ── Password ──────────────────────────────────────────────────────────────────
async function changePassword(){
  if($('cp-new').value!==$('cp-new2').value){al('al-chpass','New passwords do not match',false);return;}
  const r=await api('change_password',{old_pass:$('cp-old').value,new_pass:$('cp-new').value});
  al('al-chpass',r.msg,r.ok);
  if(r.ok){$('cp-old').value=$('cp-new').value=$('cp-new2').value='';}
}

// Clock + init
setInterval(()=>$('uclock').textContent=new Date().toLocaleTimeString(),1000);
loadOv();setInterval(loadOv,60000);
</script>
</body></html>
HTML

log "User panel HTML written"

# phpMyAdmin symlinks
ln -sfn /opt/phpmyadmin "${PANEL_DIR}/admin/public/phpmyadmin" 2>/dev/null || true
ln -sfn /opt/phpmyadmin "${PANEL_DIR}/user/public/phpmyadmin"  2>/dev/null || true
log "phpMyAdmin linked into both panels"


# =============================================================================
# STEP 8 — phpMyAdmin symlinks
# =============================================================================
hdr "Step 8 · phpMyAdmin Symlinks"
ln -sfn /opt/phpmyadmin "${PANEL_DIR}/admin/public/phpmyadmin" 2>/dev/null || true
ln -sfn /opt/phpmyadmin "${PANEL_DIR}/user/public/phpmyadmin"  2>/dev/null || true
log "phpMyAdmin symlinked"

# =============================================================================
# STEP 9 — Apache vHosts for panels
# =============================================================================
hdr "Step 9 · Apache Panel vHosts"

# Disable mod_php — it conflicts with proxy_fcgi FPM handler
# Must be done BEFORE writing vhosts that use SetHandler proxy:unix
for phpmod in 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4; do
    a2dismod "php${phpmod}" 2>/dev/null || true
done

# Enable required modules
for mod in proxy proxy_fcgi rewrite headers expires setenvif actions alias; do
    a2enmod "$mod" 2>/dev/null || true
done
a2enconf "php${PHP_VER}-fpm" 2>/dev/null || true

# Register ports
grep -q "Listen ${ADMIN_PORT}" /etc/apache2/ports.conf || echo "Listen ${ADMIN_PORT}" >> /etc/apache2/ports.conf
grep -q "Listen ${USER_PORT}"  /etc/apache2/ports.conf || echo "Listen ${USER_PORT}"  >> /etc/apache2/ports.conf

# Restart PHP-FPM so its socket exists before Apache loads
systemctl restart "php${PHP_VER}-fpm"
log "PHP-FPM restarted"

# Wait for socket — up to 15 seconds
for i in $(seq 1 15); do
    [[ -S "${FPM_SOCK_PATH}" ]] && break
    sleep 1
    warn "Waiting for FPM socket... ${i}s"
done

if [[ ! -S "${FPM_SOCK_PATH}" ]]; then
    die "FPM socket never appeared at ${FPM_SOCK_PATH} — check: systemctl status php${PHP_VER}-fpm"
fi
log "FPM socket confirmed: ${FPM_SOCK_PATH}"


# Write vhost configs using printf — socket path is embedded as literal string
# This avoids ALL heredoc variable expansion problems that caused php8.4/php-fpm.sock bugs
printf '%s\n' \
    "# WebPanel Admin — port ${ADMIN_PORT}" \
    "<VirtualHost *:${ADMIN_PORT}>" \
    "    ServerName localhost" \
    "    DocumentRoot ${PANEL_DIR}/admin/public" \
    "    DirectoryIndex index.php index.html" \
    "    <Directory ${PANEL_DIR}/admin/public>" \
    "        Options -Indexes +FollowSymLinks" \
    "        AllowOverride All" \
    "        Require all granted" \
    "    </Directory>" \
    "    <Directory ${PANEL_DIR}/shared>" \
    "        Require all denied" \
    "    </Directory>" \
    "    <FilesMatch \"\.php\$\">" \
    "        SetHandler \"proxy:unix:${FPM_SOCK_PATH}|fcgi://localhost\"" \
    "    </FilesMatch>" \
    "    Alias /phpmyadmin /opt/phpmyadmin" \
    "    <Directory /opt/phpmyadmin>" \
    "        Options -Indexes +FollowSymLinks" \
    "        AllowOverride All" \
    "        Require all granted" \
    "        <FilesMatch \"\.php\$\">" \
    "            SetHandler \"proxy:unix:${FPM_SOCK_PATH}|fcgi://localhost\"" \
    "        </FilesMatch>" \
    "    </Directory>" \
    "    ErrorLog  \${APACHE_LOG_DIR}/webpanel_admin_error.log" \
    "    CustomLog \${APACHE_LOG_DIR}/webpanel_admin_access.log combined" \
    "</VirtualHost>" \
    > /etc/apache2/sites-available/webpanel-admin.conf

printf '%s\n' \
    "# WebPanel User — port ${USER_PORT}" \
    "<VirtualHost *:${USER_PORT}>" \
    "    ServerName localhost" \
    "    DocumentRoot ${PANEL_DIR}/user/public" \
    "    DirectoryIndex index.php index.html" \
    "    <Directory ${PANEL_DIR}/user/public>" \
    "        Options -Indexes +FollowSymLinks" \
    "        AllowOverride All" \
    "        Require all granted" \
    "    </Directory>" \
    "    <Directory ${PANEL_DIR}/shared>" \
    "        Require all denied" \
    "    </Directory>" \
    "    <FilesMatch \"\.php\$\">" \
    "        SetHandler \"proxy:unix:${FPM_SOCK_PATH}|fcgi://localhost\"" \
    "    </FilesMatch>" \
    "    Alias /phpmyadmin /opt/phpmyadmin" \
    "    <Directory /opt/phpmyadmin>" \
    "        Options -Indexes +FollowSymLinks" \
    "        AllowOverride All" \
    "        Require all granted" \
    "        <FilesMatch \"\.php\$\">" \
    "            SetHandler \"proxy:unix:${FPM_SOCK_PATH}|fcgi://localhost\"" \
    "        </FilesMatch>" \
    "    </Directory>" \
    "    ErrorLog  \${APACHE_LOG_DIR}/webpanel_user_error.log" \
    "    CustomLog \${APACHE_LOG_DIR}/webpanel_user_access.log combined" \
    "</VirtualHost>" \
    > /etc/apache2/sites-available/webpanel-user.conf

# Verify the socket path was written correctly
log "Socket in admin vhost: $(grep 'proxy:unix' /etc/apache2/sites-available/webpanel-admin.conf | head -1 | xargs)"
log "Socket in user  vhost: $(grep 'proxy:unix' /etc/apache2/sites-available/webpanel-user.conf  | head -1 | xargs)"

a2ensite webpanel-admin webpanel-user 2>/dev/null
apachectl configtest 2>&1
systemctl reload apache2
log "Panel vHosts enabled on :${ADMIN_PORT} and :${USER_PORT}"

# =============================================================================
# STEP 10 — Sudoers
# =============================================================================
hdr "Step 10 · Sudoers"

cat > /etc/sudoers.d/webpanel << SUDO
# WebPanel — www-data needs these to manage hosting accounts
# User management
www-data ALL=(ALL) NOPASSWD: /usr/sbin/useradd
www-data ALL=(ALL) NOPASSWD: /usr/sbin/userdel *
www-data ALL=(ALL) NOPASSWD: /usr/sbin/usermod *
www-data ALL=(ALL) NOPASSWD: /usr/bin/chpasswd
www-data ALL=(ALL) NOPASSWD: /usr/sbin/groupadd *
www-data ALL=(ALL) NOPASSWD: /usr/bin/gpasswd *
# Filesystem
www-data ALL=(ALL) NOPASSWD: /bin/mkdir -p *
www-data ALL=(ALL) NOPASSWD: /bin/chown *
www-data ALL=(ALL) NOPASSWD: /bin/chmod *
www-data ALL=(ALL) NOPASSWD: /bin/mv /tmp/wp_* *
www-data ALL=(ALL) NOPASSWD: /bin/mv /tmp/cron_* *
www-data ALL=(ALL) NOPASSWD: /bin/rm -rf /home/*
www-data ALL=(ALL) NOPASSWD: /usr/bin/ln -sfn *
www-data ALL=(ALL) NOPASSWD: /usr/bin/touch *
www-data ALL=(ALL) NOPASSWD: /usr/bin/du -sm *
www-data ALL=(ALL) NOPASSWD: /usr/bin/setfacl *
# Apache
www-data ALL=(ALL) NOPASSWD: /usr/sbin/a2ensite *
www-data ALL=(ALL) NOPASSWD: /usr/sbin/a2dissite *
www-data ALL=(ALL) NOPASSWD: /usr/sbin/apachectl configtest
www-data ALL=(ALL) NOPASSWD: /bin/systemctl reload apache2
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart apache2
# PHP-FPM (both reload and restart needed)
www-data ALL=(ALL) NOPASSWD: /bin/systemctl reload php${PHP_VER}-fpm
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart php${PHP_VER}-fpm
# Services
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start apache2
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop apache2
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start mariadb
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop mariadb
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart mariadb
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start redis-server
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop redis-server
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart redis-server
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start vsftpd
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart vsftpd
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start postfix
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart postfix
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start memcached
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart memcached
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start fail2ban
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart fail2ban
www-data ALL=(ALL) NOPASSWD: /bin/systemctl status *
www-data ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status *
www-data ALL=(ALL) NOPASSWD: /usr/sbin/ufw status
www-data ALL=(ALL) NOPASSWD: /usr/bin/certbot *
www-data ALL=(ALL) NOPASSWD: /usr/bin/crontab *
www-data ALL=(ALL) NOPASSWD: /usr/bin/tar *
SUDO
chmod 440 /etc/sudoers.d/webpanel
visudo -c -f /etc/sudoers.d/webpanel && log "Sudoers valid" || warn "Sudoers check failed"

# =============================================================================
# STEP 11 — System groups + permissions
# =============================================================================
hdr "Step 11 · Groups & Permissions"
groupadd webpanel-users 2>/dev/null || true
groupadd sftp-users     2>/dev/null || true

chown -R www-data:www-data "${PANEL_DIR}"
chmod -R 750 "${PANEL_DIR}"
chmod 640 "${PANEL_DIR}/shared/config/config.php"
chmod 700 "${PANEL_DIR}/storage/sessions"
chmod 755 "${PANEL_DIR}/admin/public" "${PANEL_DIR}/user/public"
chown www-data:www-data "${PANEL_DIR}/storage/sessions"
log "Permissions set"

# SFTP chroot in sshd_config (idempotent)
if ! grep -q "Match Group sftp-users" /etc/ssh/sshd_config 2>/dev/null; then
    cat >> /etc/ssh/sshd_config << 'SSHEOF'

# WebPanel SFTP chroot
Match Group sftp-users
    ChrootDirectory /home/%u
    ForceCommand internal-sftp -l INFO
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
SSHEOF
    sshd -t && systemctl reload sshd 2>/dev/null || warn "sshd config issue — check /etc/ssh/sshd_config"
    log "SFTP chroot configured"
fi

# Logrotate for hosting account logs
cat > /etc/logrotate.d/webpanel-hosting << 'LOGROTATE'
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

# =============================================================================
# STEP 12 — Seed admin account
# =============================================================================
hdr "Step 12 · Admin Account"

php -r "
define('WP_VERSION','3.0.0');
define('PHP_VER','${PHP_VER}');
define('PANEL_DIR','${PANEL_DIR}');
define('PANEL_SECRET','${PANEL_SECRET}');
define('MYSQL_ROOT','${MYSQL_ROOT_PASS}');
define('DB_HOST','localhost');
define('DB_NAME','${PANEL_DB}');
define('DB_USER','${PANEL_DB_USER}');
define('DB_PASS','${PANEL_DB_PASS}');
define('APACHE_SITES','/etc/apache2/sites-available');
define('APACHE_ENABLED','/etc/apache2/sites-enabled');
define('PHP_FPM_POOLS','/etc/php/${PHP_VER}/fpm/pool.d');
define('PHP_FPM_SOCK','/run/php');
define('FPM_SOCK_PATH','${FPM_SOCK_PATH}');
define('PMA_DIR','/opt/phpmyadmin');
define('SESSION_DIR','${PANEL_DIR}/storage/sessions');
define('SESSION_LIFE',7200);
define('ADMIN_PORT','${ADMIN_PORT}');
define('USER_PORT','${USER_PORT}');
define('PANEL_GROUP','webpanel-users');
define('FTP_USERLIST','/etc/vsftpd.userlist');
define('HOSTNAME',gethostname());
require '${PANEL_DIR}/shared/lib/DB.php';
DB::init();
\$h = password_hash('${ADMIN_PASS}', PASSWORD_BCRYPT, ['cost'=>12]);
\$db = DB::panel();
\$db->prepare('INSERT INTO panel_users (username,password_hash,email,role) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE password_hash=?')
    ->execute(['${ADMIN_USER}',\$h,'admin@localhost','admin',\$h]);
echo \"Admin seeded OK\n\";
"
log "Admin account seeded"

# =============================================================================
# STEP 13 — Save credentials
# =============================================================================
SERVER_IP="$(hostname -I | awk '{print $1}')"
cat >> "${CRED_FILE}" << EOF

# ════════════════════════════════════════════
#  WebPanel v3.0 — $(date)
# ════════════════════════════════════════════
Admin_Panel_URL     = http://${SERVER_IP}:${ADMIN_PORT}
User_Panel_URL      = http://${SERVER_IP}:${USER_PORT}
Admin_Username      = ${ADMIN_USER}
Admin_Password      = ${ADMIN_PASS}
Panel_DB_Name       = ${PANEL_DB}
Panel_DB_User       = ${PANEL_DB_USER}
Panel_DB_Pass       = ${PANEL_DB_PASS}
Panel_Directory     = ${PANEL_DIR}
PHP_Version         = ${PHP_VER}
FPM_Socket          = ${FPM_SOCK_PATH}
EOF
chmod 600 "${CRED_FILE}"

# =============================================================================
# DONE — Final verification
# =============================================================================
hdr "✔  Installation Complete"

echo ""
echo "  Services:"
for svc in apache2 "php${PHP_VER}-fpm" mariadb; do
    systemctl is-active --quiet "$svc" \
        && echo -e "    ${G}✔${N} $svc" \
        || echo -e "    ${R}✘${N} $svc — NOT running"
done

echo ""
echo "  FPM socket:"
ls -la "${FPM_SOCK_PATH}" 2>/dev/null && echo -e "    ${G}✔${N} Socket exists" || echo -e "    ${R}✘${N} Socket MISSING"

echo ""
echo "  HTTP test:"
sleep 2
for port in "${ADMIN_PORT}" "${USER_PORT}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" --max-time 5 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|302|301)$ ]]; then
        echo -e "    ${G}✔${N} Port ${port} → HTTP ${code}"
    else
        echo -e "    ${R}✘${N} Port ${port} → HTTP ${code} — check /var/log/apache2/error.log"
    fi
done

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Admin Panel : http://${SERVER_IP}:${ADMIN_PORT}            │"
echo "  │  Username    : ${ADMIN_USER}                                │"
echo "  │  Password    : ${ADMIN_PASS}                 │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │  User  Panel : http://${SERVER_IP}:${USER_PORT}            │"
echo "  │  phpMyAdmin  : http://${SERVER_IP}:${ADMIN_PORT}/phpmyadmin │"
echo "  │  Creds file  : cat ${CRED_FILE}           │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
log "Install log: ${LOG_FILE}"
