#!/usr/bin/env bash
# ============================================================
#  Harbor Home Lab — Setup Script
#  Версия Harbor: v2.13.1
# ============================================================
set -euo pipefail

HARBOR_VERSION="v2.13.1"
HARBOR_DIR="/opt/harbor"
DATA_DIR="/data/harbor"
CERT_DIR="/data/harbor/certs"

# ---- Цвета ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Проверка root ----
[[ $EUID -ne 0 ]] && error "Запустите скрипт от root или через sudo"

# ---- Читаем harbor.env ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/harbor.env"
[[ -f "$ENV_FILE" ]] || error "Файл $ENV_FILE не найден"
# shellcheck source=/dev/null
source "$ENV_FILE"

HOSTNAME="${HARBOR_HOSTNAME:?Укажите HARBOR_HOSTNAME в harbor.env}"
ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?Укажите HARBOR_ADMIN_PASSWORD в harbor.env}"
HTTP_PORT="${HARBOR_HTTP_PORT:-80}"
HTTPS_PORT="${HARBOR_HTTPS_PORT:-443}"
USE_HTTPS="${HARBOR_USE_HTTPS:-true}"

# ================================================================
#  1. Зависимости
# ================================================================
check_deps() {
  info "Проверка зависимостей..."
  for cmd in docker openssl wget tar; do
    command -v "$cmd" &>/dev/null || error "Не найдена утилита: $cmd"
  done
  docker compose version &>/dev/null 2>&1 || \
    docker-compose version &>/dev/null 2>&1 || \
    error "Не найден docker compose / docker-compose"
  info "Все зависимости присутствуют"
}

# ================================================================
#  2. TLS-сертификаты (самоподписные для homelab)
# ================================================================
generate_certs() {
  [[ "$USE_HTTPS" == "false" ]] && { warn "HTTPS отключён — пропуск генерации сертификатов"; return; }
  info "Генерация самоподписных TLS-сертификатов для: $HOSTNAME"
  mkdir -p "$CERT_DIR"

  # CA
  openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -sha512 -days 3650 \
    -subj "/C=RU/ST=Home/L=Lab/O=HomeLab/CN=HomeLab-CA" \
    -key "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.crt" 2>/dev/null

  # Server key + CSR
  openssl genrsa -out "$CERT_DIR/harbor.key" 4096 2>/dev/null
  openssl req -sha512 -new \
    -subj "/C=RU/ST=Home/L=Lab/O=HomeLab/CN=$HOSTNAME" \
    -key "$CERT_DIR/harbor.key" \
    -out "$CERT_DIR/harbor.csr" 2>/dev/null

  # SAN-расширение (поддержка IP-адресов)
  cat > "$CERT_DIR/v3.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $HOSTNAME
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF

  # Если HOSTNAME — это IP-адрес, добавим его
  if [[ "$HOSTNAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "IP.2  = $HOSTNAME" >> "$CERT_DIR/v3.ext"
  fi

  openssl x509 -req -sha512 -days 3650 \
    -extfile "$CERT_DIR/v3.ext" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -in  "$CERT_DIR/harbor.csr" \
    -out "$CERT_DIR/harbor.crt" 2>/dev/null

  # Конвертация для Docker-демона
  openssl x509 -inform PEM -in "$CERT_DIR/harbor.crt" \
    -out "$CERT_DIR/harbor.cert" 2>/dev/null

  chmod 600 "$CERT_DIR"/*.key

  info "Сертификаты созданы в $CERT_DIR"
  warn "Чтобы Docker-клиенты доверяли реестру:"
  echo "  mkdir -p /etc/docker/certs.d/$HOSTNAME"
  echo "  cp $CERT_DIR/harbor.cert /etc/docker/certs.d/$HOSTNAME/ca.crt"
  echo "  systemctl restart docker"
}

# ================================================================
#  3. Скачивание Harbor
# ================================================================
download_harbor() {
  if [[ -d "$HARBOR_DIR" ]]; then
    warn "Каталог $HARBOR_DIR уже существует — пропуск загрузки"
    return
  fi
  info "Загрузка Harbor $HARBOR_VERSION..."
  local TMP; TMP=$(mktemp -d)
  wget -q --show-progress \
    "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz" \
    -O "$TMP/harbor.tgz"
  tar -xzf "$TMP/harbor.tgz" -C /opt/
  rm -rf "$TMP"
  info "Harbor распакован в $HARBOR_DIR"
}

# ================================================================
#  4. Генерация harbor.yml
# ================================================================
write_harbor_yml() {
  info "Генерация $HARBOR_DIR/harbor.yml..."
  mkdir -p "$DATA_DIR"

  if [[ "$USE_HTTPS" == "true" ]]; then
    HTTPS_BLOCK="https:
  port: ${HTTPS_PORT}
  certificate: ${CERT_DIR}/harbor.crt
  private_key: ${CERT_DIR}/harbor.key"
  else
    HTTPS_BLOCK="# https отключён — только HTTP"
  fi

  cat > "$HARBOR_DIR/harbor.yml" <<EOF
# ============================================================
#  Harbor Configuration — Home Lab
#  Сгенерировано setup.sh
# ============================================================

hostname: ${HOSTNAME}

http:
  port: ${HTTP_PORT}

${HTTPS_BLOCK}

harbor_admin_password: ${ADMIN_PASSWORD}

database:
  password: harbor_db_secret
  max_idle_conns: 50
  max_open_conns: 100
  conn_max_lifetime: 5m
  conn_max_idle_time: 0

data_volume: ${DATA_DIR}

trivy:
  # Сканер уязвимостей Trivy
  ignore_unfixed: false
  skip_update: false
  offline_scan: false
  security_check: vuln
  insecure: false

jobservice:
  max_job_workers: 10

notification:
  webhook_job_max_retry: 3

log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200m
    location: /var/log/harbor

_version: 2.13.0

proxy:
  http_proxy:
  https_proxy:
  no_proxy:
  components:
    - core
    - jobservice
    - trivy

upload_purging:
  enabled: true
  age: 168h
  interval: 24h
  dryrun: false

cache:
  enabled: false
  expire_hours: 24
EOF
  info "harbor.yml записан"
}

# ================================================================
#  5. Запуск install.sh
# ================================================================
run_installer() {
  info "Запуск harbor/install.sh (с Trivy)..."
  cd "$HARBOR_DIR"
  bash install.sh --with-trivy
  info "Harbor успешно запущен!"
}

# ================================================================
#  6. Настройка Docker-демона (insecure-registry для HTTP)
# ================================================================
configure_docker_daemon() {
  [[ "$USE_HTTPS" == "true" ]] && return
  warn "Настройка Docker для работы с HTTP-реестром..."
  local DAEMON_JSON="/etc/docker/daemon.json"
  if [[ -f "$DAEMON_JSON" ]]; then
    warn "$DAEMON_JSON уже существует — добавьте вручную:"
    echo '  "insecure-registries": ["'"$HOSTNAME:$HTTP_PORT"'"]'
  else
    cat > "$DAEMON_JSON" <<EOF
{
  "insecure-registries": ["${HOSTNAME}:${HTTP_PORT}"]
}
EOF
    systemctl restart docker
    info "Docker перезапущен с insecure-registry"
  fi
}

# ================================================================
#  Main
# ================================================================
main() {
  echo ""
  echo "  ██╗  ██╗ █████╗ ██████╗ ██████╗  ██████╗ ██████╗"
  echo "  ██║  ██║██╔══██╗██╔══██╗██╔══██╗██╔═══██╗██╔══██╗"
  echo "  ███████║███████║██████╔╝██████╔╝██║   ██║██████╔╝"
  echo "  ██╔══██║██╔══██║██╔══██╗██╔══██╗██║   ██║██╔══██╗"
  echo "  ██║  ██║██║  ██║██║  ██║██████╔╝╚██████╔╝██║  ██║"
  echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝"
  echo "                                          Home Lab Setup"
  echo ""

  check_deps
  generate_certs
  download_harbor
  write_harbor_yml
  configure_docker_daemon
  run_installer

  echo ""
  info "=========================================="
  info "  Harbor готов!"
  if [[ "$USE_HTTPS" == "true" ]]; then
    info "  URL:  https://${HOSTNAME}:${HTTPS_PORT}"
  else
    info "  URL:  http://${HOSTNAME}:${HTTP_PORT}"
  fi
  info "  Логин: admin / ${ADMIN_PASSWORD}"
  info "=========================================="
  echo ""
  info "Управление:"
  echo "  cd $HARBOR_DIR && docker compose ps"
  echo "  cd $HARBOR_DIR && docker compose stop"
  echo "  cd $HARBOR_DIR && docker compose start"
}

main "$@"
