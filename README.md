# rw-node-xanmod

Скрипт автоматической подготовки VPS под установку [Remnawave Node](https://docs.rw/docs/install/remnawave-node).

## Что делает

- Устанавливает [XanMod](https://xanmod.org) ядро (автоматически определяет `x64v2`/`x64v3` по флагам CPU)
- Включает BBR + fq qdisc
- Устанавливает и настраивает UFW с правилами только для нужных портов
- Настраивает Fail2ban для защиты SSH (3 попытки → бан на 24 часа)
- Ставит [MOTD](https://github.com/distillium/motd) с преднастроенным конфигом
- Устанавливает таймзону `Europe/Moscow`
- Переименовывает хост
- Кладёт утилиту `kernel-cleanup` для удаления старых ядер

## Требования

- Debian 12 (Bookworm)
- Root-доступ
- IP адрес панели Remnawave

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/trillvertual/rw-node-xanmod/main/setup.sh)
```

Скрипт интерактивный — спросит:
- **Имя хоста** (например `FR-1`)
- **IP панели** Remnawave
- **Тип ноды** — обычная или с selfsteal (открывает порт 8443)

## После установки

Сервер перезагрузится автоматически. Дальше:

1. Установить Docker
2. Добавить ноду в панели Remnawave
3. Скопировать `docker-compose.yml` из панели в `/opt/remnanode/`
4. Запустить `docker compose up -d`

## Полезные команды

```bash
# Удалить старые ядра после обновления
kernel-cleanup

# Статус firewall
ufw status verbose

# Забаненные IP в fail2ban
fail2ban-client status sshd
```

## Порты

| Порт | Протокол | Доступ     | Назначение       |
|------|----------|------------|------------------|
| 22   | TCP      | Anywhere   | SSH              |
| 443  | TCP      | Anywhere   | Xray Reality     |
| 2222 | TCP      | IP панели  | Remnawave Panel  |
| 9100 | TCP      | IP панели  | Node Exporter    |
| 8443 | TCP      | Anywhere   | Selfsteal (опц.) |
