#!/usr/bin/env bash

set -e

echo "==== Xray Ultimate Optimizer PRO ===="

### --- ПРОВЕРКА ROOT ---
if [ "$EUID" -ne 0 ]; then
    echo "Запусти как root"
    exit 1
fi

### --- УСТАНОВКА ЗАВИСИМОСТЕЙ ---
echo "== Установка зависимостей =="

apt update -y
apt install -y curl jq ufw fail2ban

# Установка yq (YAML парсер)
if ! command -v yq &> /dev/null; then
    echo "Устанавливаем yq..."
    YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    curl -L $YQ_URL -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi

### --- ВЫБОР УСТАНОВКИ ---
echo ""
echo "Где установлен Xray?"
echo "1) Host (systemd)"
echo "2) Docker"
read -p "Выбор [1-2]: " INSTALL_TYPE

### --- RAM ---
echo ""
read -p "Сколько RAM (GB): " RAM

if [ "$RAM" -le 1 ]; then
    SOMAX=32768
    BACKLOG=8192
    RMEM=8388608
    WMEM=8388608
    SWAPSIZE=2
elif [ "$RAM" -le 2 ]; then
    SOMAX=65535
    BACKLOG=16384
    RMEM=16777216
    WMEM=16777216
    SWAPSIZE=2
else
    SOMAX=65535
    BACKLOG=32768
    RMEM=33554432
    WMEM=33554432
    SWAPSIZE=4
fi

echo "Профиль применён"

### --- УБИРАЕМ GOMEMLIMIT ---
sed -i '/GOMEMLIMIT/d' /etc/environment || true
sed -i '/GOGC/d' /etc/environment || true

### --- SYSTEMD ---
if [ "$INSTALL_TYPE" == "1" ]; then
    mkdir -p /etc/systemd/system/xray.service.d

    cat > /etc/systemd/system/xray.service.d/override.conf <<EOF
[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
LimitNOFILE=1048576
EOF

    systemctl daemon-reload
fi

### --- SYSCTL ---
cat > /etc/sysctl.d/99-xray.conf <<EOF
net.core.somaxconn = $SOMAX
net.ipv4.tcp_max_syn_backlog = $BACKLOG
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.core.rmem_max = $RMEM
net.core.wmem_max = $WMEM
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
vm.swappiness = 10
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system

### --- SWAP ---
if [ ! -f /swapfile ]; then
    fallocate -l ${SWAPSIZE}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAPSIZE*1024))
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

### --- DOCKER ---
DOCKER_CONTAINER=""

if [ "$INSTALL_TYPE" == "2" ]; then

    if ! command -v docker &> /dev/null; then
        echo "Docker не установлен!"
        exit 1
    fi

    echo "== Поиск контейнера =="

    CONTAINERS=$(docker ps --format "{{.Names}} {{.Image}}" | grep -Ei "xray|v2ray|x-ui|3x-ui" || true)

    if [ -z "$CONTAINERS" ]; then
        docker ps
        read -p "Имя контейнера: " DOCKER_CONTAINER
    else
        echo "$CONTAINERS"

        COUNT=$(echo "$CONTAINERS" | wc -l)

        if [ "$COUNT" -eq 1 ]; then
            DOCKER_CONTAINER=$(echo "$CONTAINERS" | awk '{print $1}')
        else
            i=1
            declare -a LIST
            while read -r line; do
                NAME=$(echo "$line" | awk '{print $1}')
                echo "$i) $NAME"
                LIST[$i]=$NAME
                ((i++))
            done <<< "$CONTAINERS"

            read -p "Выбор: " CHOICE
            DOCKER_CONTAINER=${LIST[$CHOICE]}
        fi
    fi

    echo "Контейнер: $DOCKER_CONTAINER"

    ### --- DOCKER COMPOSE PATCH ---
    echo "== Поиск docker-compose.yml =="

    COMPOSE_FILE=$(find / -maxdepth 3 -name "docker-compose.yml" 2>/dev/null | head -n 1)

    if [ -n "$COMPOSE_FILE" ]; then
        echo "Найден: $COMPOSE_FILE"

        read -p "Пропатчить compose? (y/n): " PATCH

        if [ "$PATCH" == "y" ]; then
            cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"

            # Найти сервис с Xray
            SERVICE=$(yq e '.services | keys | .[]' "$COMPOSE_FILE" | while read s; do
                IMAGE=$(yq e ".services.$s.image" "$COMPOSE_FILE")
                echo "$IMAGE" | grep -qiE "xray|v2ray|x-ui" && echo "$s"
            done | head -n1)

            if [ -z "$SERVICE" ]; then
                echo "❌ Сервис не найден"
            else
                echo "Сервис: $SERVICE"

                yq e -i ".services.$SERVICE.cap_add += [\"NET_ADMIN\",\"NET_BIND_SERVICE\"]" "$COMPOSE_FILE"

                yq e -i ".services.$SERVICE.ulimits.nofile.soft = 1048576" "$COMPOSE_FILE"
                yq e -i ".services.$SERVICE.ulimits.nofile.hard = 1048576" "$COMPOSE_FILE"

                echo "compose обновлён"

                DIR=$(dirname "$COMPOSE_FILE")
                cd "$DIR"

                docker compose up -d || docker-compose up -d
            fi
        fi
    fi
fi

### --- XRAY PORTS ---
XRAY_CONFIG=""
for path in /usr/local/etc/xray/config.json /etc/xray/config.json; do
    [ -f "$path" ] && XRAY_CONFIG="$path"
done

if [ -z "$XRAY_CONFIG" ]; then
    read -p "config.json путь: " XRAY_CONFIG
fi

DETECTED_PORTS=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" | sort -u)

AUTO_PORTS=""
for p in $DETECTED_PORTS; do
    AUTO_PORTS+="$p/both,"
done
AUTO_PORTS=${AUTO_PORTS%,}

read -p "Использовать авто-порты? (y/n): " USE_AUTO

if [ "$USE_AUTO" == "y" ]; then
    PORTS="$AUTO_PORTS"
else
    read -p "Порты: " PORTS
fi

### --- UFW ---
read -p "Включить UFW? (y/n): " USE_UFW

if [ "$USE_UFW" == "y" ]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit ssh

    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"

    for entry in "${PORT_ARRAY[@]}"; do
        PORT=$(echo "$entry" | cut -d'/' -f1)
        TYPE=$(echo "$entry" | cut -d'/' -f2)

        [ "$TYPE" == "tcp" ] && ufw allow "$PORT/tcp"
        [ "$TYPE" == "udp" ] && ufw allow "$PORT/udp"
        [ "$TYPE" == "both" ] && { ufw allow "$PORT/tcp"; ufw allow "$PORT/udp"; }
    done

    ufw --force enable
fi

### --- FAIL2BAN ---
read -p "Включить Fail2Ban? (y/n): " USE_F2B

if [ "$USE_F2B" == "y" ]; then
    mkdir -p /etc/fail2ban/filter.d

    cat > /etc/fail2ban/filter.d/xray.conf <<EOF
[Definition]
failregex = rejected .* from <HOST>
            invalid user .* <HOST>
ignoreregex =
EOF

    mkdir -p /var/log/xray
    touch /var/log/xray/access.log

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 15

[xray]
enabled = true
port = $(echo $DETECTED_PORTS | tr ' ' ',')
filter = xray
logpath = /var/log/xray/access.log
EOF

    systemctl restart fail2ban
fi

### --- RESTART ---
if [ "$INSTALL_TYPE" == "1" ]; then
    systemctl restart xray
else
    docker restart "$DOCKER_CONTAINER"
fi

echo "=== ГОТОВО ==="
