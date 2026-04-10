#!/bin/bash
# ============================================
# Remnawave Node — подготовка сервера
# Debian 12 + XanMod + Security
# ============================================

set -e

# --- Проверка root ---
if [ "$EUID" -ne 0 ]; then
  echo "Запусти от root"
  exit 1
fi

clear
echo "==========================================="
echo "  Подготовка VPS для Remnawave Node"
echo "==========================================="
echo

# ==============================
# СБОР ПАРАМЕТРОВ
# ==============================

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

# --- Определение уровня CPU ---
CPU_FLAGS=$(awk '/flags/{print; exit}' /proc/cpuinfo)
if echo "$CPU_FLAGS" | grep -q "avx2"; then
  XANMOD_PKG="linux-xanmod-x64v3"
else
  XANMOD_PKG="linux-xanmod-x64v2"
fi

echo
echo "==========================================="
echo "  Параметры:"
echo "  Hostname:  $HOSTNAME"
echo "  Panel IP:  $PANEL_IP"
echo "  Selfsteal: $([[ $NODE_TYPE == 2 ]] && echo 'да' || echo 'нет')"
echo "  XanMod:    $XANMOD_PKG"
echo "==========================================="
read -rp "Продолжить? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || exit 0

# ==============================
# 1. HOSTNAME
# ==============================
echo
echo "[1/8] Установка hostname..."
hostnamectl set-hostname "$HOSTNAME"

# ==============================
# 2. БАЗОВЫЕ ПАКЕТЫ
# ==============================
echo "[2/8] Обновление системы и установка пакетов..."
apt update && apt upgrade -y
apt install -y sudo ufw nano git wget curl net-tools cron socat fail2ban

# ==============================
# 3. XANMOD
# ==============================
echo "[3/8] Установка XanMod..."
mkdir -p /etc/apt/keyrings
wget -qO - https://dl.xanmod.org/archive.key | \
  gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org bookworm main" | \
  tee /etc/apt/sources.list.d/xanmod-release.list
apt update && apt install -y "$XANMOD_PKG"

# BBR
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# ==============================
# 4. KERNEL CLEANUP SCRIPT
# ==============================
echo "[4/8] Установка kernel-cleanup..."
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

# ==============================
# 5. UFW
# ==============================
echo "[5/8] Настройка UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 443/tcp comment 'Xray Reality'
ufw allow from "$PANEL_IP" to any port 2222 proto tcp comment 'Remnawave Panel'
ufw allow from "$PANEL_IP" to any port 9100 proto tcp comment 'Node Exporter'

if [ "$NODE_TYPE" == "2" ]; then
  ufw allow 8443/tcp comment 'Selfsteal'
fi

ufw --force enable

# ==============================
# 6. FAIL2BAN
# ==============================
echo "[6/8] Настройка fail2ban..."
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

# ==============================
# 7. MOTD + ТАЙМЗОНА
# ==============================
echo "[7/8] Установка MOTD..."
curl -fsSL https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh | bash
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

# ==============================
# 8. ГОТОВО
# ==============================
echo
echo "==========================================="
echo "  Установка завершена!"
echo "==========================================="
echo
ufw status verbose
echo
echo "Ребут через 10 секунд... Ctrl+C для отмены"
sleep 10
reboot
