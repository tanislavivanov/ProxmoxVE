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
$STD apt-get install -y \
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
$STD apt-get update
$STD apt-get install -y \
  postgresql-client-13 \
  postgresql-client-14 \
  postgresql-client-15 \
  postgresql-client-16 \
  postgresql-client-17
msg_ok "Installed Dependencies"

NODE_VERSION="22" setup_nodejs
setup_go

msg_info "Installing Build Tools (task, goose, sqlc)"
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
$STD go install github.com/go-task/task/v3/cmd/task@latest
$STD go install github.com/pressly/goose/v3/cmd/goose@latest
$STD go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest
cp /root/go/bin/task /usr/local/bin/
cp /root/go/bin/goose /usr/local/bin/
cp /root/go/bin/sqlc /usr/local/bin/
msg_ok "Installed Build Tools"

msg_info "Installing PG Back Web"
RELEASE=$(get_latest_github_release "eduardolat/pgbackweb")
$STD git clone -b "${RELEASE}" --depth 1 https://github.com/eduardolat/pgbackweb.git /opt/pgbackweb
cd /opt/pgbackweb

export GOBIN=/usr/local/go/bin
export PATH=$PATH:/usr/local/go/bin:/root/go/bin

$STD npm install
$STD go mod download
$STD task build

mkdir -p /opt/pgbackweb/dist
cp /opt/pgbackweb/cmd/changepw/changepw /usr/local/bin/pgbackweb-changepw 2>/dev/null || \
  cp /opt/pgbackweb/dist/change-password /usr/local/bin/pgbackweb-changepw 2>/dev/null || true
chmod +x /usr/local/bin/pgbackweb-changepw 2>/dev/null || true

PG_DB_PASS=$(openssl rand -hex 16)
PBW_ENCRYPTION_KEY=$(openssl rand -hex 32)
cat <<EOF >/opt/pgbackweb/.env
PBW_ENCRYPTION_KEY="${PBW_ENCRYPTION_KEY}"
PBW_POSTGRES_CONN_STRING="postgresql://pgbackweb:${PG_DB_PASS}@localhost:5432/pgbackweb?sslmode=disable"
PBW_LISTEN_PORT="8085"
PBW_LISTEN_HOST="0.0.0.0"
EOF
chmod 600 /opt/pgbackweb/.env

echo "${RELEASE}" >~/.pgbackweb
msg_ok "Installed PG Back Web ${RELEASE}"

msg_info "Setting up PostgreSQL Database"
PG_VERSION="17" setup_postgresql
PG_DB_NAME="pgbackweb" PG_DB_USER="pgbackweb" PG_DB_PASS="${PG_DB_PASS}" PG_DB_SKIP_ALTER_ROLE="true" setup_postgresql_db
msg_ok "Set up PostgreSQL Database"

msg_info "Running Database Migrations"
source /opt/pgbackweb/.env
$STD goose -dir /opt/pgbackweb/internal/database/migrations postgres "${PBW_POSTGRES_CONN_STRING}" up
msg_ok "Ran Database Migrations"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/pgbackweb.service
[Unit]
Description=PG Back Web
Documentation=https://github.com/eduardolat/pgbackweb
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pgbackweb
EnvironmentFile=/opt/pgbackweb/.env
ExecStart=/opt/pgbackweb/dist/app
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now pgbackweb
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
