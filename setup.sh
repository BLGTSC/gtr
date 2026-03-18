#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
info()    { echo -e "${CYAN}[->]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
die()     { echo -e "${RED}[EROARE] $1${NC}"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }

GITHUB_ZIP="https://github.com/BLGTSC/gtr/raw/main/gametracker-complete.zip"
INSTALL_DIR="/var/www/gametracker"
APP_USER="www-data"
PHP_VER="8.3"

[ "$EUID" -ne 0 ] && die "Ruleaza ca root: sudo bash setup.sh"

clear
echo ""
echo "  ============================================"
echo "  GameTracker - Setup Ubuntu 22.04 Fresh"
echo "  Nginx + PHP 8.3 + MySQL + Redis"
echo "  ============================================"
echo ""

section "Date configurare"

read -rp "[?] Domeniu sau IP (ex: 1.2.3.4): " DOMAIN
[ -z "$DOMAIN" ] && die "Campul nu poate fi gol."

read -rsp "[?] Parola MySQL pentru user gametracker: " DB_PASS
echo
[ -z "$DB_PASS" ] && die "Parola MySQL nu poate fi goala."

read -rp "[?] Email admin [admin@${DOMAIN}]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"

read -rsp "[?] Parola admin panel: " ADMIN_PASS
echo
[ -z "$ADMIN_PASS" ] && die "Parola admin nu poate fi goala."

read -rp "[?] SSL Let's Encrypt? (y/n) [n]: " DO_SSL
DO_SSL="${DO_SSL:-n}"

echo ""
echo "  Domeniu:  $DOMAIN"
echo "  Director: $INSTALL_DIR"
echo "  Admin:    $ADMIN_EMAIL"
echo ""
read -rp "[?] Continui? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && { warn "Anulat."; exit 0; }

section "1/9 - Update sistem"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git unzip zip \
    software-properties-common gnupg2 ca-certificates \
    lsb-release apt-transport-https \
    ufw supervisor cron acl build-essential
ok "Sistem actualizat"

section "2/9 - PHP 8.3"
add-apt-repository -y ppa:ondrej/php 2>/dev/null
apt-get update -y -qq
apt-get install -y -qq \
    php${PHP_VER} \
    php${PHP_VER}-fpm \
    php${PHP_VER}-cli \
    php${PHP_VER}-mysql \
    php${PHP_VER}-redis \
    php${PHP_VER}-bcmath \
    php${PHP_VER}-ctype \
    php${PHP_VER}-curl \
    php${PHP_VER}-fileinfo \
    php${PHP_VER}-mbstring \
    php${PHP_VER}-openssl \
    php${PHP_VER}-pdo \
    php${PHP_VER}-tokenizer \
    php${PHP_VER}-xml \
    php${PHP_VER}-zip \
    php${PHP_VER}-intl \
    php${PHP_VER}-sockets \
    php${PHP_VER}-gd \
    php${PHP_VER}-opcache

FPM_POOL="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
sed -i 's/^pm = .*/pm = dynamic/' "$FPM_POOL"
sed -i 's/^pm.max_children = .*/pm.max_children = 20/' "$FPM_POOL"
sed -i 's/^pm.start_servers = .*/pm.start_servers = 4/' "$FPM_POOL"
sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "$FPM_POOL"
sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 6/' "$FPM_POOL"

for INI in "/etc/php/${PHP_VER}/fpm/php.ini" "/etc/php/${PHP_VER}/cli/php.ini"; do
    [ -f "$INI" ] || continue
    sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' "$INI"
    sed -i 's/^post_max_size = .*/post_max_size = 64M/' "$INI"
    sed -i 's/^memory_limit = .*/memory_limit = 256M/' "$INI"
    sed -i 's/^max_execution_time = .*/max_execution_time = 120/' "$INI"
    grep -qxF 'extension=sockets' "$INI" || echo 'extension=sockets' >> "$INI"
done

systemctl enable "php${PHP_VER}-fpm" --quiet
systemctl restart "php${PHP_VER}-fpm"
ok "PHP ${PHP_VER} instalat cu sockets activat"

section "3/9 - Nginx"
apt-get install -y -qq nginx
systemctl enable nginx --quiet
mkdir -p "${INSTALL_DIR}/public"
chown -R "${APP_USER}:${APP_USER}" /var/www

cat > /etc/nginx/sites-available/gametracker << NGINXEOF
limit_req_zone \$binary_remote_addr zone=query_zone:10m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${INSTALL_DIR}/public;
    index index.php;
    charset utf-8;

    access_log /var/log/nginx/gametracker_access.log;
    error_log  /var/log/nginx/gametracker_error.log;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 120;
    }

    location = /query.php {
        limit_req zone=query_zone burst=10 nodelay;
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 15;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location ~ /\.(env|git|htaccess) {
        deny all;
        return 404;
    }

    client_max_body_size 64M;
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/gametracker /etc/nginx/sites-enabled/gametracker
nginx -t 2>/dev/null && systemctl restart nginx
ok "Nginx configurat pentru ${DOMAIN}"

section "4/9 - MySQL 8.0"
apt-get install -y -qq mysql-server
systemctl enable mysql --quiet
systemctl start mysql

mysql -u root << SQLEOF
CREATE DATABASE IF NOT EXISTS gametracker CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'gametracker'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON gametracker.* TO 'gametracker'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
ok "MySQL: baza de date + user create"

section "5/9 - Redis"
apt-get install -y -qq redis-server
sed -i 's/^# maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
systemctl enable redis-server --quiet
systemctl restart redis-server
ok "Redis pornit"

section "6/9 - Composer + Node.js 20"
if ! command -v composer &>/dev/null; then
    curl -sS https://getcomposer.org/installer -o /tmp/cs.php
    php /tmp/cs.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/cs.php
fi
ok "Composer instalat"

curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs
ok "Node.js $(node --version) instalat"

section "7/9 - Download din GitHub"
info "Descarc zip-ul..."
wget -q --show-progress -O /tmp/gametracker.zip "${GITHUB_ZIP}" || \
    die "Nu pot descarca zip-ul de pe GitHub. Verifica conexiunea."

info "Dezarhivez..."
mkdir -p "${INSTALL_DIR}"
unzip -q /tmp/gametracker.zip -d /tmp/gt_ex

if [ -d /tmp/gt_ex/gametracker ]; then
    cp -rf /tmp/gt_ex/gametracker/. "${INSTALL_DIR}/"
else
    cp -rf /tmp/gt_ex/. "${INSTALL_DIR}/"
fi
rm -rf /tmp/gametracker.zip /tmp/gt_ex
chown -R "${APP_USER}:${APP_USER}" "${INSTALL_DIR}"
ok "Fisiere copiate in ${INSTALL_DIR}"

section "8/9 - Configurare Laravel"
cd "${INSTALL_DIR}"

[ ! -f .env.example ] && die "Nu gasesc .env.example in ${INSTALL_DIR}. Zip-ul pare invalid."

cp .env.example .env

sed -i "s|APP_URL=.*|APP_URL=http://${DOMAIN}|" .env
sed -i "s|APP_ENV=.*|APP_ENV=production|" .env
sed -i "s|APP_DEBUG=.*|APP_DEBUG=false|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=gametracker|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=gametracker|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=${ADMIN_EMAIL}|" .env
sed -i "s|ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASS}|" .env
sed -i "s|QUERY_API_URL=.*|QUERY_API_URL=http://${DOMAIN}/query.php|" .env
ok ".env configurat"

info "Composer install (1-2 minute)..."
sudo -u "${APP_USER}" composer install \
    --optimize-autoloader --no-dev --no-interaction 2>&1 | tail -3
ok "Composer gata"

info "npm build..."
npm ci --silent 2>/dev/null || npm install --silent
npm run build 2>/dev/null
ok "Assets compilate"

php artisan key:generate --force
php artisan migrate --force
php artisan db:seed --force
php artisan storage:link 2>/dev/null || true
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan icons:cache 2>/dev/null || true
php artisan filament:upgrade 2>/dev/null || true
ok "Laravel configurat"

section "9/9 - Supervisor, Firewall, Cron"

chown -R "${APP_USER}:${APP_USER}" "${INSTALL_DIR}"
chmod -R 775 "${INSTALL_DIR}/storage" "${INSTALL_DIR}/bootstrap/cache"
ok "Permisiuni setate"

cat > /etc/supervisor/conf.d/gametracker.conf << SUPEOF
[program:gametracker-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${INSTALL_DIR}/artisan queue:work redis --queue=queries,default --sleep=3 --tries=3 --timeout=60 --max-jobs=500
directory=${INSTALL_DIR}
autostart=true
autorestart=true
numprocs=2
stopwaitsecs=3600
user=${APP_USER}
redirect_stderr=true
stdout_logfile=/var/log/supervisor/gametracker-worker.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
SUPEOF

systemctl enable supervisor --quiet
systemctl restart supervisor
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
ok "Supervisor: 2x queue workers"

CRON_CMD="* * * * * cd ${INSTALL_DIR} && php artisan schedule:run >> /dev/null 2>&1"
( crontab -u "${APP_USER}" -l 2>/dev/null | grep -vF "artisan schedule:run"; echo "${CRON_CMD}" ) \
    | crontab -u "${APP_USER}" -
ok "Cron adaugat"

ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow OpenSSH >/dev/null 2>&1
ufw allow 'Nginx Full' >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ok "Firewall activ"

systemctl restart "php${PHP_VER}-fpm"
systemctl restart nginx
systemctl restart redis-server
supervisorctl restart all >/dev/null 2>&1 || true
ok "Servicii repornite"

if [ "$DO_SSL" = "y" ]; then
    section "SSL - Let's Encrypt"
    apt-get install -y -qq certbot python3-certbot-nginx
    warn "DNS-ul pentru ${DOMAIN} trebuie sa pointeze catre IP-ul acestui VPS!"
    read -rp "[?] Continui cu certbot? (y/n): " SSL_CONFIRM
    if [ "$SSL_CONFIRM" = "y" ]; then
        certbot --nginx \
            -d "${DOMAIN}" -d "www.${DOMAIN}" \
            --non-interactive --agree-tos \
            --email "${ADMIN_EMAIL}" --redirect 2>/dev/null \
        && {
            ok "SSL instalat"
            sed -i "s|APP_URL=http://|APP_URL=https://|" "${INSTALL_DIR}/.env"
            sed -i "s|QUERY_API_URL=http://|QUERY_API_URL=https://|" "${INSTALL_DIR}/.env"
            php artisan config:cache
        } || warn "SSL esuat - ruleaza manual: certbot --nginx -d ${DOMAIN}"
    fi
fi

section "Verificare finala"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/" 2>/dev/null || echo "000")
case "$HTTP_CODE" in
    200|301|302) ok "Site accesibil HTTP ${HTTP_CODE}" ;;
    *) warn "Site returneaza HTTP ${HTTP_CODE} - verifica: tail -f /var/log/nginx/gametracker_error.log" ;;
esac

redis-cli ping 2>/dev/null | grep -q "PONG" && ok "Redis OK" || warn "Redis nu raspunde"

echo ""
echo "============================================"
echo "  GameTracker instalat cu succes!"
echo "============================================"
echo ""
echo "  Site:        http://${DOMAIN}"
echo "  Admin panel: http://${DOMAIN}/admin"
echo "  Email:       ${ADMIN_EMAIL}"
echo "  Parola:      ${ADMIN_PASS}"
echo "  query.php:   http://${DOMAIN}/query.php?ip=89.42.132.29&port=27015"
echo ""
echo "  Loguri:"
echo "    tail -f /var/log/nginx/gametracker_error.log"
echo "    tail -f /var/log/supervisor/gametracker-worker.log"
echo "    tail -f ${INSTALL_DIR}/storage/logs/laravel.log"
echo ""
