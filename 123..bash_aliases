#!/bin/bash

# Очистка экрана
clear

# Создание директории и файла для отключения предупреждений
mkdir -p ~/.cloudshell && touch ~/.cloudshell/no-apt-get-warning
echo "Установка зависимостей..."

# Установка необходимых пакетов: WireGuard и iproute2 для работы с таблицами маршрутизации
sudo apt-get update -y --fix-missing && sudo apt-get install wireguard-tools iproute2 jq curl -y --fix-missing

# Генерация приватного и публичного ключей, если не переданы в качестве аргументов
priv="${1:-$(wg genkey)}"
pub="${2:-$(echo "${priv}" | wg pubkey)}"

# API для взаимодействия с Cloudflare Warp
api="https://api.cloudflareclient.com/v0i1909051800"

# Функции для работы с API
ins() { curl -s -H 'user-agent:' -H 'content-type: application/json' -X "$1" "${api}/$2" "${@:3}"; }
sec() { ins "$1" "$2" -H "authorization: Bearer $3" "${@:4}"; }

# Регистрация через API и получение токенов
response=$(ins POST "reg" -d "{"install_id":"","tos":"$(date -u +%FT%T.000Z)","key":"${pub}","fcm_token":"","type":"ios","locale":"en_US"}")
id=$(echo "$response" | jq -r '.result.id')
token=$(echo "$response" | jq -r '.result.token')
response=$(sec PATCH "reg/${id}" "$token" -d '{"warp_enabled":true}')

# Получение информации о peer (пире) для подключения
peer_pub=$(echo "$response" | jq -r '.result.config.peers[0].public_key')
peer_endpoint=$(echo "$response" | jq -r '.result.config.peers[0].endpoint.host')
client_ipv4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4')
client_ipv6=$(echo "$response" | jq -r '.result.config.interface.addresses.v6')
port=$(echo "$peer_endpoint" | sed 's/.:([0-9])$/\1/')
peer_endpoint=$(echo "$peer_endpoint" | sed 's/(.):[0-9]/162.159.193.5/')

# Создание конфигурационного файла WireGuard
conf=$(cat <<-EOM
[Interface]
PrivateKey = ${priv}
Address = ${client_ipv4}, ${client_ipv6}
DNS = 1.1.1.1, 2606:4700:4700::1111, 1.0.0.1, 2606:4700:4700::1001

[Peer]
PublicKey = ${peer_pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${peer_endpoint}:${port}
EOM
)

# Вывод конфигурации в терминал
clear
echo -e "\n\n\n"
[ -t 1 ] && echo "########## НАЧАЛО КОНФИГА ##########"
echo "${conf}"
[ -t 1 ] && echo "########### КОНЕЦ КОНФИГА ###########"

# Преобразование конфигурации в Base64 для возможности скачивания через ссылку
conf_base64=$(echo -n "${conf}" | base64 -w 0)
echo "Скачать конфиг файлом: https://immalware.github.io/downloader.html?filename=WARP.conf&content=${conf_base64}"

# Получение IP-адресов Discord (примерные IP-диапазоны, обновляются при необходимости)
discord_ips=("162.159.128.0/24" "162.159.129.0/24")

# Создание новой таблицы маршрутизации для Discord
ip rule add fwmark 1 table 51820
ip route add default dev wg0 table 51820

# Добавление iptables правил для маршрутизации только Discord
for ip in "${discord_ips[@]}"; do
    iptables -t mangle -A OUTPUT -d "$ip" -p tcp --dport 443 -j MARK --set-mark 1
done

# Запуск WireGuard с новой конфигурацией
wg-quick up wg0