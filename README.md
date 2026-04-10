# rw-node-xanmod

Универсальный скрипт для подготовки и апгрейда VPS под [Remnawave Node](https://docs.rw/docs/install/remnawave-node).

## Что делает

Один скрипт, два режима на выбор при запуске:

### 1. Setup — чистая установка

Полная настройка новой VPS с Debian 12:

- [XanMod LTS](https://xanmod.org) ядро (автоматически `x64v2`/`x64v3` по флагам CPU)
- BBR + fq qdisc
- UFW (обычная нода или selfsteal)
- Fail2ban для защиты SSH (3 попытки → бан 24 часа)
- Оптимизации: tuned (`network-throughput`), irqbalance, haveged, systemd-timesyncd
- Unattended-upgrades — автоматические security-патчи (ядро в blacklist)
- [MOTD](https://github.com/distillium/motd) с преднастроенным конфигом
- Таймзона `Europe/Moscow`
- Утилита `kernel-cleanup` для удаления старых ядер

В конце автоматический ребут через 10 секунд.

### 2. Upgrade — апгрейд существующей ноды

Идемпотентный режим — добавляет только то, чего не хватает:

- Ставит недостающие утилиты (tuned, irqbalance, haveged, timesyncd, unattended-upgrades)
- Переключает XanMod на LTS-ветку (если ещё не стоит)
- Исправляет репозиторий xanmod на `bookworm` если стоит `releases` (фикс libbpf1)
- Применяет профиль `network-throughput`
- Настраивает автоматические security-обновления
- **НЕ трогает** существующие правила UFW, fail2ban, MOTD, hostname, sysctl
- Ребут только по подтверждению и только если установлено новое ядро

## Требования

- Debian 12 (Bookworm)
- Root-доступ
- Для режима Setup — IP адрес панели Remnawave

## Запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/trillvertual/rw-node-xanmod/main/setup.sh)
```

Скрипт спросит режим (Setup или Upgrade) и дальше пойдёт по выбранному сценарию.

## После установки

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

# Активный профиль tuned
tuned-adm active

# Проверить синхронизацию времени
timedatectl status
```

## Порты

| Порт | Протокол | Доступ     | Назначение       |
|------|----------|------------|------------------|
| 22   | TCP      | Anywhere   | SSH              |
| 443  | TCP      | Anywhere   | Xray Reality     |
| 2222 | TCP      | IP панели  | Remnawave Panel  |
| 9100 | TCP      | IP панели  | Node Exporter    |
| 8443 | TCP      | Anywhere   | Selfsteal (опц.) |
