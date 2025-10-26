#!/usr/bin/env bash
set -euo pipefail

# === EDIT THESE ===
DOMAIN="aceda.id.vn"   # hostname(s) cho cert và nginx (space separated)
SSH_PORT=2222
ADMIN_USER="tuananh"                     # user to create
# ==================

# Update & basic packages
apt update && apt upgrade -y
apt install -y curl gnupg lsb-release software-properties-common apt-transport-https ca-certificates

# Create admin user if not exists
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    adduser --gecos "" "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
    mkdir -p /home/"$ADMIN_USER"/.ssh
    chmod 700 /home/"$ADMIN_USER"/.ssh
    echo "Thêm public key của bạn vào /home/$ADMIN_USER/.ssh/authorized_keys rồi tiếp tục" 
    read -p "Đã thêm public key? (enter để tiếp tục) "
fi

# SSH hardening
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config || true
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
systemctl reload sshd

# Install core stack: nginx, php, mariadb, redis, certbot
apt install -y nginx mariadb-server redis-server unzip git
# Add PHP repo for PHP 8.2
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y php8.2-fpm php8.2-mysql php8.2-redis php8.2-curl php8.2-mbstring php8.2-xml php8.2-gd php8.2-zip

# Enable services
systemctl enable --now nginx php8.2-fpm mariadb redis

# MariaDB secure and tune (interactive minimal)
mysql_secure_installation <<EOF

y
secret_root_pass_here
secret_root_pass_here
y
y
y
y
EOF

# Basic MariaDB tuning (adjust later)
cat > /etc/mysql/mariadb.conf.d/50-server-tuning.cnf <<'EOF'
[mysqld]
innodb_buffer_pool_size=4G
innodb_log_file_size=512M
max_connections=400
query_cache_type=0
tmp_table_size=128M
max_heap_table_size=128M
EOF
systemctl restart mariadb

# Create web root
WEBROOT="/var/www/aceda"
mkdir -p "$WEBROOT"
chown -R www-data:www-data "$WEBROOT"
chmod -R 755 "$WEBROOT"

# Install certbot
apt install -y certbot python3-certbot-nginx

# Setup UFW
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Install fail2ban
apt install -y fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = {SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600

[nginx-http-auth]
enabled = true
EOF
sed -i "s/{SSH_PORT}/$SSH_PORT/" /etc/fail2ban/jail.local
systemctl restart fail2ban

# nginx cache snippet & vhost placeholder
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/cache.conf <<'EOF'
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=mycache:200m max_size=50g inactive=60m use_temp_path=off;
fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2 keys_zone=fcache:200m max_size=50g inactive=60m;
EOF

# vhost template
cat > /etc/nginx/sites-available/aceda <<'EOF'
include /etc/nginx/snippets/cache.conf;

server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/aceda;
    index index.php index.html;

    # security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "no-referrer-when-downgrade";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;

        fastcgi_cache fcache;
        fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
        fastcgi_cache_valid 200 302 10m;
        fastcgi_cache_bypass \$cookie_SESSION;
        add_header X-Cache-Status \$upstream_cache_status;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|webp)$ {
        try_files \$uri =404;
        access_log off;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000";
    }

    # deny access to hidden files
    location ~ /\. {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/aceda /etc/nginx/sites-enabled/aceda
nginx -t && systemctl reload nginx

# Install netdata (lightweight monitoring)
bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait

echo "Setup completed. Please:
- upload your site files to /var/www/aceda
- run: sudo certbot --nginx -d yourdomain (replacing yourdomain)
- check MariaDB root password and create DB/user.
- adjust innodb_buffer_pool_size depending on RAM."
