# ============================================================
#  Makefile — удобное управление Harbor Home Lab
# ============================================================
HARBOR_DIR   := /opt/harbor
DATA_DIR     := /data/harbor

.PHONY: install status start stop restart logs ps backup clean help

help:
	@echo ""
	@echo "  Harbor Home Lab — команды управления"
	@echo ""
	@echo "  make install    — первичная установка"
	@echo "  make status     — статус контейнеров"
	@echo "  make start      — запуск"
	@echo "  make stop       — остановка"
	@echo "  make restart    — перезапуск"
	@echo "  make logs       — логи (все сервисы)"
	@echo "  make ps         — список контейнеров"
	@echo "  make backup     — бэкап данных"
	@echo "  make clean      — полная очистка (ОСТОРОЖНО!)"
	@echo ""

install:
	@sudo bash setup.sh

status ps:
	@cd $(HARBOR_DIR) && docker compose ps

start:
	@cd $(HARBOR_DIR) && docker compose start
	@echo "Harbor запущен"

stop:
	@cd $(HARBOR_DIR) && docker compose stop
	@echo "Harbor остановлен"

restart:
	@cd $(HARBOR_DIR) && docker compose stop && docker compose start
	@echo "Harbor перезапущен"

logs:
	@cd $(HARBOR_DIR) && docker compose logs -f --tail=100

backup:
	@echo "Создание бэкапа..."
	@BACKUP_NAME="harbor-backup-$$(date +%Y%m%d-%H%M%S).tar.gz"; \
	  sudo tar -czf "/tmp/$$BACKUP_NAME" \
	    --exclude="$(DATA_DIR)/trivy-cache" \
	    $(DATA_DIR) && \
	  echo "Бэкап: /tmp/$$BACKUP_NAME"

clean:
	@echo "ВНИМАНИЕ: это удалит все данные Harbor!"
	@read -p "Продолжить? (yes/no): " ans && [ "$$ans" = "yes" ]
	@cd $(HARBOR_DIR) && docker compose down -v
	@sudo rm -rf $(DATA_DIR)
	@echo "Очищено"
