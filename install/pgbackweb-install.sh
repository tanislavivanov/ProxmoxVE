#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Tanislav Ivanov (tanislavivanov)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/eduardolat/pgbackweb

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  wget \
  curl \
  git \
  unzip \
  gnupg \
  postgresql-common \
  make \
  gcc \
  g++
$STD /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
$STD apt update
$STD apt install -y \
  postgresql-client-13 \
  postgresql-client-14 \
  postgresql-client-15 \
  postgresql-client-16 \
  postgresql-client-17 \
  postgresql-client-18
msg_ok "Installed Dependencies"

NODE_VERSION="22" setup_nodejs
setup_go

msg_info "Installing Goose & SQLC"
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
$STD go install github.com/pressly/goose/v3/cmd/goose@latest
$STD go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest
cp /root/go/bin/goose /usr/local/bin/
cp /root/go/bin/sqlc /usr/local/bin/
msg_ok "Installed Goose & SQLC"

msg_info "Installing PG Back Web"
cd /opt
RELEASE=$(get_latest_github_release "eduardolat/pgbackweb")
$STD git clone -b "${RELEASE}" --depth 1 https://github.com/eduardolat/pgbackweb.git /opt/pgbackweb
cd /opt/pgbackweb

$STD npm install
$STD go mod download
$STD npm run tailwindcss -- --minify --config ./tailwind.config.ts --input ./internal/view/static/css/style.css --output ./internal/view/static/build/style.min.css
$STD node ./scripts/build-js.ts
$STD node ./scripts/sqlc-prebuild.ts
$STD sqlc generate
$STD go build -o ./dist/app ./cmd/app/.
$STD go build -o ./dist/change-password ./cmd/changepw/.
cp ./dist/change-password /usr/local/bin/change-password
chmod +x /usr/local/bin/change-password

PG_DB_PASS=$(openssl rand -hex 16)
cat <<EOF >/opt/pgbackweb/.env
PBW_ENCRYPTION_KEY="$(openssl rand -hex 32)"
PBW_POSTGRES_CONN_STRING="postgresql://pgbackweb:${PG_DB_PASS}@localhost:5432/pgbackweb?sslmode=disable"
PBW_LISTEN_PORT="8085"
PBW_LISTEN_HOST="0.0.0.0"
EOF

cat <<EOF >/opt/pgbackweb/run.sh
#!/bin/bash
source /opt/pgbackweb/.env
/usr/local/bin/goose -dir /opt/pgbackweb/internal/database/migrations postgres "\${PBW_POSTGRES_CONN_STRING}" up
exec /opt/pgbackweb/dist/app
EOF
chmod +x /opt/pgbackweb/run.sh
echo "${RELEASE}" >~/.pgbackweb
msg_ok "Installed PG Back Web"

msg_info "Setting up Database"
PG_VERSION="17" PG_MODULES="" setup_postgresql
PG_DB_NAME="pgbackweb" PG_DB_USER="pgbackweb" PG_DB_PASS="${PG_DB_PASS}" setup_postgresql_db
msg_ok "Set up Database"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/pgbackweb.service
[Unit]
Description=PG Back Web Service
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pgbackweb
EnvironmentFile=/opt/pgbackweb/.env
ExecStart=/opt/pgbackweb/run.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now pgbackweb
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
