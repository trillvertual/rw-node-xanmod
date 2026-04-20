#!/bin/bash
# ============================================
# rw-node-xanmod
# Подготовка / апгрейд Remnawave Node
# Debian 12 + XanMod LTS + Security + Tuning
# ============================================

set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS='-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef'

if [ "$EUID" -ne 0 ]; then
  echo "Запусти от root"
  exit 1
fi

wait_for_dpkg() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    echo "  Ожидание освобождения dpkg lock..."
    sleep 3
  done
}

# ============================================
# ВЫБОР РЕЖИМА
# ============================================
clear
echo "==========================================="
echo "  rw-node-xanmod"
echo "==========================================="
echo
echo "  1) Setup   — чистая установка новой ноды"
echo "  2) Upgrade — апгрейд уже настроенной ноды"
echo "  3) Выход"
echo
read -rp "Выбор [1/2/3]: " MODE
while [[ "$MODE" != "1" && "$MODE" != "2" && "$MODE" != "3" ]]; do
  read -rp "Введи 1, 2 или 3: " MODE
done
[[ "$MODE" == "3" ]] && exit 0

# ============================================
# ОПРЕДЕЛЕНИЕ УРОВНЯ CPU
# ============================================
CPU_FLAGS=$(awk '/flags/{print; exit}' /proc/cpuinfo)
if echo "$CPU_FLAGS" | grep -q "avx2"; then
  LTS_PKG="linux-xanmod-lts-x64v3"
else
  LTS_PKG="linux-xanmod-lts-x64v2"
fi

# ============================================
# ОБЩИЕ ФУНКЦИИ
# ============================================

install_xanmod_repo() {
  mkdir -p /etc/apt/keyrings
  # Проверяем что ключ существует И не пустой (битые файлы с прошлых попыток)
  NEED_KEY=1
  [ -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ] && NEED_KEY=0
  [ -s /usr/share/keyrings/xanmod-archive-keyring.gpg ] && NEED_KEY=0

  if [ "$NEED_KEY" == "1" ]; then
    # Удаляем битые пустые файлы если есть
    [ -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ] && \
      [ ! -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ] && \
      rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg

    # Пробуем разные способы скачать ключ
    KEY_DATA=""
    for i in 1 2 3; do
      KEY_DATA=$(wget -qO - https://dl.xanmod.org/archive.key 2>/dev/null) && [ -n "$KEY_DATA" ] && break
      KEY_DATA=$(curl -fsSL https://dl.xanmod.org/archive.key 2>/dev/null) && [ -n "$KEY_DATA" ] && break
      KEY_DATA=$(curl -fsSL -A "Mozilla/5.0" https://dl.xanmod.org/archive.key 2>/dev/null) && [ -n "$KEY_DATA" ] && break
      if command -v gpg >/dev/null; then
        gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 86F7D09EE734E623 2>/dev/null && \
        gpg --export 86F7D09EE734E623 > /etc/apt/keyrings/xanmod-archive-keyring.gpg && \
        [ -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ] && break
      fi
      sleep 5
    done

    # Если через HTTP скачали — конвертируем
    if [ -n "$KEY_DATA" ] && [ ! -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
      echo "$KEY_DATA" | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
    fi

    # Финальная проверка
    if [ ! -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
      echo "  Ошибка: не удалось установить GPG ключ xanmod"
      exit 1
    fi
  fi

  if [ -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
    KEY_PATH="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
  else
    KEY_PATH="/usr/share/keyrings/xanmod-archive-keyring.gpg"
  fi
  rm -f /etc/apt/sources.list.d/xanmod-*.list
  echo "deb [signed-by=${KEY_PATH}] http://deb.xanmod.org bookworm main" | \
    tee /etc/apt/sources.list.d/xanmod-release.list
}

apply_optimizations() {
  systemctl enable --now tuned >/dev/null 2>&1
  tuned-adm profile network-throughput
  echo "  tuned → network-throughput"

  systemctl enable --now irqbalance >/dev/null 2>&1
  echo "  irqbalance → включён"

  systemctl enable --now haveged >/dev/null 2>&1
  echo "  haveged → включён"

  systemctl enable --now systemd-timesyncd >/dev/null 2>&1
  timedatectl set-ntp true
  echo "  systemd-timesyncd → включён"
}

setup_unattended_upgrades() {
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist {
    "linux-";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable --now unattended-upgrades >/dev/null 2>&1
}

show_status() {
  echo
  echo "Активные сервисы:"
  echo "  tuned:      $(tuned-adm active 2>/dev/null | grep -oP '(?<=profile: ).*')"
  echo "  irqbalance: $(systemctl is-active irqbalance)"
  echo "  haveged:    $(systemctl is-active haveged)"
  echo "  timesync:   $(systemctl is-active systemd-timesyncd)"
  echo "  unattended: $(systemctl is-active unattended-upgrades)"
}

# ============================================
# SETUP MODE
# ============================================
if [ "$MODE" == "1" ]; then

  echo
  echo "=== SETUP — чистая установка ==="
  echo

  read -rp "Имя хоста (например FR-1): " HOSTNAME
  while [ -z "$HOSTNAME" ]; do
    read -rp "Имя хоста не может быть пустым: " HOSTNAME
  done

  read -rp "IP панели Remnawave: " PANEL_IP
  while [[ ! "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
    read -rp "Неверный формат. IP панели: " PANEL_IP
  done

  echo
  echo "Тип ноды:"
  echo "  1) Обычная (без selfsteal)"
  echo "  2) Selfsteal (открыть порт 8443)"
  read -rp "Выбор [1/2]: " NODE_TYPE
  while [[ "$NODE_TYPE" != "1" && "$NODE_TYPE" != "2" ]]; do
    read -rp "Введи 1 или 2: " NODE_TYPE
  done

  echo
  echo "==========================================="
  echo "  Параметры:"
  echo "  Hostname:  $HOSTNAME"
  echo "  Panel IP:  $PANEL_IP"
  echo "  Selfsteal: $([[ $NODE_TYPE == 2 ]] && echo 'да' || echo 'нет')"
  echo "  XanMod:    $LTS_PKG (LTS)"
  echo "==========================================="
  read -rp "Продолжить? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[yY]$ ]] || exit 0

  echo
  echo "[1/9] Установка hostname..."
  hostnamectl set-hostname "$HOSTNAME"

  echo "[2/9] Обновление системы и установка пакетов..."
  # Удаляем возможно сломанный xanmod-репозиторий с прошлых попыток
  # (восстановим его правильно в шаге 3)
  rm -f /etc/apt/sources.list.d/xanmod-*.list
  rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg
  wait_for_dpkg
  apt-get update
  wait_for_dpkg
  apt-get upgrade -y $APT_OPTS
  wait_for_dpkg
  apt-get install -y $APT_OPTS sudo ufw nano git wget curl net-tools cron socat \
    fail2ban psmisc expect tuned irqbalance haveged systemd-timesyncd unattended-upgrades gnupg

  echo "[3/9] Установка XanMod LTS..."
  install_xanmod_repo
  wait_for_dpkg
  apt-get update
  wait_for_dpkg

  # Пробуем установить мета-пакет с ретраями
  META_INSTALLED=0
  for i in 1 2 3; do
    if apt-get install -y $APT_OPTS "$LTS_PKG"; then
      META_INSTALLED=1
      break
    fi
    echo "  Попытка $i не удалась, жду 15 секунд..."
    sleep 15
    apt-get clean
    apt-get update
  done

  # Если мета-пакет не ставится (404 на CDN) — ставим image+headers напрямую
  if [ "$META_INSTALLED" == "0" ]; then
    echo "  Мета-пакет недоступен (проблема на стороне xanmod CDN)"
    echo "  Устанавливаю image + headers напрямую..."
    # Находим последнюю доступную версию ядра через apt
    KERNEL_VER=$(apt-cache search "^linux-image-.*-$(echo $LTS_PKG | grep -oP 'x64v\d')-xanmod1$" | \
                 awk '{print $1}' | sort -V | tail -1 | \
                 sed 's/linux-image-//')
    if [ -n "$KERNEL_VER" ]; then
      apt-get install -y $APT_OPTS \
        "linux-image-${KERNEL_VER}" \
        "linux-headers-${KERNEL_VER}"
    else
      echo "  Ошибка: не удалось определить версию ядра"
      exit 1
    fi
  fi

  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p

  echo "[4/9] Установка kernel-cleanup..."
  cat > /usr/local/sbin/kernel-cleanup << 'SCRIPT'
#!/bin/bash
CURRENT=$(uname -r)
echo "Текущее ядро: $CURRENT"
REMOVE=$(dpkg -l | grep 'linux-image-[0-9]' | grep '^ii' | awk '{print $2}' | grep -v "$CURRENT")
if [ -z "$REMOVE" ]; then
  echo "Нечего удалять."
  exit 0
fi
echo "Удаляю: $REMOVE"
apt purge -y $REMOVE && apt autoremove -y && update-grub
SCRIPT
  chmod +x /usr/local/sbin/kernel-cleanup

  echo "[5/9] Настройка UFW..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed
  ufw allow 22/tcp comment 'SSH'
  ufw allow 443/tcp comment 'Xray Reality'
  ufw allow from "$PANEL_IP" to any port 2222 proto tcp comment 'Remnawave Panel'
  ufw allow from "$PANEL_IP" to any port 9100 proto tcp comment 'Node Exporter'
  [ "$NODE_TYPE" == "2" ] && ufw allow 8443/tcp comment 'Selfsteal'
  ufw --force enable

  echo "[6/9] Настройка fail2ban..."
  cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 86400
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = 22
filter = sshd
maxretry = 3
bantime = 86400
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban

  echo "[7/9] Применение оптимизаций..."
  apply_optimizations
  setup_unattended_upgrades

  echo "[8/9] Установка MOTD..."
  # Останавливаем unattended-upgrades чтобы не конфликтовал с установкой MOTD
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl mask unattended-upgrades 2>/dev/null || true
  wait_for_dpkg
  expect <<'EXPECT'
set timeout 300
spawn bash -c "curl -fsSL https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh | bash"
expect {
    -re "Continue.*:" { send "y\r"; exp_continue }
    -re "Продолжить.*:" { send "y\r"; exp_continue }
    -re "Choice.*:" { send "1\r"; exp_continue }
    -re "Выбор.*:" { send "1\r"; exp_continue }
    timeout { exit 1 }
    eof
}
EXPECT

  timedatectl set-timezone Europe/Moscow

  cat > /etc/dist-motd.conf << 'EOF'
MOTDSET_LANG=ru
SHOW_LOGO=false
SHOW_CPU=true
SHOW_MEM=true
SHOW_NET=true
SHOW_DOCKER=false
SHOW_DOCKER_STATUS=false
SHOW_DOCKER_RUNNING_LIST=false
SHOW_FIREWALL=true
SHOW_FIREWALL_RULES=false
SHOW_UPDATES=true
SHOW_SECURITY=false
SERVICES_STATUS_ENABLED=false
SERVICES=()
EOF

  # Возвращаем unattended-upgrades
  systemctl unmask unattended-upgrades 2>/dev/null || true
  systemctl start unattended-upgrades 2>/dev/null || true

  echo "[9/9] Готово."
  echo
  echo "==========================================="
  echo "  Установка завершена!"
  echo "==========================================="
  ufw status verbose
  show_status
  echo
  echo "Ребут через 10 секунд... Ctrl+C для отмены"
  sleep 10
  reboot

fi

# ============================================
# UPGRADE MODE
# ============================================
if [ "$MODE" == "2" ]; then

  echo
  echo "=== UPGRADE — апгрейд существующей ноды ==="
  echo "Скрипт добавит недостающие компоненты и переключит ядро на XanMod LTS."
  echo "Существующие настройки (UFW, fail2ban, MOTD, hostname) НЕ будут изменены."
  echo
  read -rp "Продолжить? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[yY]$ ]] || exit 0

  echo
  echo "[1/5] Установка недостающих утилит..."
  wait_for_dpkg
  apt-get update

  PACKAGES=(tuned irqbalance haveged systemd-timesyncd unattended-upgrades psmisc gnupg)
  TO_INSTALL=()
  for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      TO_INSTALL+=("$pkg")
    fi
  done

  if [ ${#TO_INSTALL[@]} -gt 0 ]; then
    echo "  Ставлю: ${TO_INSTALL[*]}"
    wait_for_dpkg
    apt-get install -y $APT_OPTS "${TO_INSTALL[@]}"
  else
    echo "  Все утилиты уже установлены."
  fi

  echo
  echo "[2/5] Проверка XanMod LTS..."

  if grep -rq "xanmod.org releases" /etc/apt/sources.list.d/ 2>/dev/null || \
     ! grep -rq "xanmod.org bookworm" /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "  Исправляю репозиторий xanmod на bookworm..."
    install_xanmod_repo
    wait_for_dpkg
    apt-get update
  fi

  NEED_REBOOT=0
  if ! dpkg -l | grep -q "linux-xanmod-lts"; then
    echo "  Устанавливаю $LTS_PKG..."
    wait_for_dpkg
    apt-get install -y $APT_OPTS "$LTS_PKG"
    NEED_REBOOT=1
  else
    echo "  XanMod LTS уже установлен."
  fi

  # Доставляем kernel-cleanup если его нет
  if [ ! -f /usr/local/sbin/kernel-cleanup ]; then
    echo "  Добавляю утилиту kernel-cleanup..."
    cat > /usr/local/sbin/kernel-cleanup << 'SCRIPT'
#!/bin/bash
CURRENT=$(uname -r)
echo "Текущее ядро: $CURRENT"
REMOVE=$(dpkg -l | grep 'linux-image-[0-9]' | grep '^ii' | awk '{print $2}' | grep -v "$CURRENT")
if [ -z "$REMOVE" ]; then
  echo "Нечего удалять."
  exit 0
fi
echo "Удаляю: $REMOVE"
apt purge -y $REMOVE && apt autoremove -y && update-grub
SCRIPT
    chmod +x /usr/local/sbin/kernel-cleanup
  fi

  echo
  echo "[3/5] Применение оптимизаций..."
  apply_optimizations

  echo
  echo "[4/5] Настройка unattended-upgrades..."
  setup_unattended_upgrades
  echo "  unattended-upgrades → только security"

  echo
  echo "[5/5] Готово."
  echo
  echo "==========================================="
  echo "  Апгрейд завершён!"
  echo "==========================================="
  show_status
  echo

  if [ "$NEED_REBOOT" == "1" ]; then
    echo "⚠️  Установлено новое ядро XanMod LTS."
    echo "    Чтобы оно активировалось, нужен ребут."
    echo "    После ребута запусти: kernel-cleanup"
    echo
    read -rp "Ребутнуть сейчас? [y/N]: " DOREBOOT
    [[ "$DOREBOOT" =~ ^[yY]$ ]] && reboot
  else
    echo "Ребут не требуется."
  fi

fi
