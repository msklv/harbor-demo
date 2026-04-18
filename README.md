# Harbor Home Lab

Полный набор скриптов для развёртывания **Harbor** (CNCF container registry)  
в домашней лаборатории через Docker Compose.

**Версия Harbor:** v2.13.1  
**Включено:** Trivy (сканер уязвимостей), TLS, лимиты ресурсов

---

## 📋 Требования

| Компонент        | Минимум        | Рекомендовано |
|------------------|----------------|---------------|
| CPU              | 2 ядра         | 4 ядра        |
| RAM              | 4 ГБ           | 8 ГБ          |
| Диск             | 40 ГБ          | 100 ГБ+       |
| Docker           | 20.10.10+      | latest        |
| Docker Compose   | 1.18+          | v2+           |
| OS               | Ubuntu 22.04 / Debian 12 / RHEL 9 |

---

## 🚀 Быстрый старт

### 1. Клонировать / скопировать файлы

```bash
git clone <этот-репо> harbor-homelab
cd harbor-homelab
```

### 2. Отредактировать конфигурацию

```bash
nano harbor.env
```

Ключевые параметры:

```env
HARBOR_HOSTNAME=harbor.homelab.local   # IP или DNS вашего сервера
HARBOR_ADMIN_PASSWORD=Harbor@HomeLab2025!
HARBOR_USE_HTTPS=true
```

> ⚠️ **Не используйте** `localhost` или `127.0.0.1` в качестве hostname —  
> Harbor должен быть доступен с других машин.

### 3. Запустить установку

```bash
chmod +x setup.sh
sudo bash setup.sh
```

Скрипт автоматически:
- Сгенерирует самоподписные TLS-сертификаты
- Скачает Harbor online installer
- Создаст `harbor.yml`
- Запустит все контейнеры

### 4. Открыть Web UI

```
https://harbor.homelab.local
Login:    admin
Password: (из harbor.env)
```

---

## 📁 Структура файлов

```
harbor-homelab/
├── setup.sh                    # Главный установочный скрипт
├── harbor.env                  # Настройки (редактировать здесь)
├── docker-compose.override.yml # Лимиты ресурсов и tweak'и
├── daemon-client.json          # Для настройки клиентских машин
├── Makefile                    # Удобные команды управления
└── README.md                   # Этот файл
```

После установки Harbor создаст:
```
/opt/harbor/                    # Бинарники и конфиги Harbor
├── docker-compose.yml          # Основной compose (генерирует install.sh)
├── harbor.yml                  # Ваш конфиг
└── ...

/data/harbor/                   # Данные (реестр, БД, кэш)
├── database/
├── registry/
├── certs/
└── trivy-cache/
```

---

## 🔧 docker-compose.override.yml

Скопируйте файл в `/opt/harbor/` после первого запуска:

```bash
sudo cp docker-compose.override.yml /opt/harbor/
cd /opt/harbor && docker compose stop && docker compose up -d
```

Override добавляет:
- `restart: unless-stopped` — автозапуск после перезагрузки сервера
- Лимиты RAM/CPU для каждого контейнера
- Персистентный кэш Trivy

---

## 🖥️ Управление

```bash
# Через Makefile
make status       # статус контейнеров
make start        # запуск
make stop         # остановка
make restart      # перезапуск
make logs         # логи
make backup       # бэкап данных

# Напрямую через docker compose
cd /opt/harbor
docker compose ps
docker compose logs -f core
docker compose restart jobservice
```

---

## 🔐 Настройка клиентских машин

### HTTPS (рекомендуется)

```bash
# На клиентской машине
HARBOR_HOST=harbor.homelab.local

sudo mkdir -p /etc/docker/certs.d/$HARBOR_HOST
sudo scp user@<harbor-server>:/data/harbor/certs/harbor.cert \
     /etc/docker/certs.d/$HARBOR_HOST/ca.crt
sudo systemctl restart docker

# Проверка
docker login $HARBOR_HOST
```

### HTTP (если HARBOR_USE_HTTPS=false)

Добавьте в `/etc/docker/daemon.json` на клиенте:
```json
{
  "insecure-registries": ["harbor.homelab.local"]
}
```
```bash
sudo systemctl restart docker
```

---

## 📦 Работа с реестром

```bash
# Логин
docker login harbor.homelab.local

# Тег и пуш образа
docker tag nginx:latest harbor.homelab.local/library/nginx:latest
docker push harbor.homelab.local/library/nginx:latest

# Пулл
docker pull harbor.homelab.local/library/nginx:latest
```

---

## 🔄 Обновление Harbor

```bash
# 1. Остановить
cd /opt/harbor && docker compose down

# 2. Бэкап данных
make backup

# 3. Скачать новую версию
wget https://github.com/goharbor/harbor/releases/download/vX.Y.Z/harbor-online-installer-vX.Y.Z.tgz
tar -xzf harbor-online-installer-vX.Y.Z.tgz -C /tmp/
sudo rsync -av /tmp/harbor/ /opt/harbor/

# 4. Перезапустить
cd /opt/harbor && sudo bash install.sh --with-trivy
```

---

## 🐛 Частые проблемы

**Контейнер `core` не стартует**  
→ Проверьте `hostname` в `harbor.yml` — не должен быть `localhost`.

**Ошибка `certificate signed by unknown authority`**  
→ Скопируйте `harbor.cert` в `/etc/docker/certs.d/<hostname>/ca.crt`  
  и перезапустите Docker.

**Мало памяти — OOM**  
→ Уменьшите `mem_limit` в `docker-compose.override.yml`  
  или добавьте swap: `sudo fallocate -l 4G /swapfile`.

**Trivy не обновляет базу уязвимостей**  
→ Проверьте доступ к интернету с сервера:  
  `docker exec harbor-trivy-adapter curl -s https://ghcr.io`

---

## 🗑️ Удаление

```bash
make clean
# или вручную:
cd /opt/harbor && docker compose down -v
sudo rm -rf /opt/harbor /data/harbor
```
