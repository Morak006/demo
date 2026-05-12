#!/bin/bash
# Ввод данных
read -p "IP eth1 [172.16.4.1/28]: " A1
A1=${A1:-172.16.4.1/28}
read -p "IP eth2 [172.16.5.1/28]: " A2
A2=${A2:-172.16.5.1/28}

# Расчет сетей (N1, N2)
N1=$(echo $A1 | cut -d'.' -f1-3).0/$(echo $A1 | cut -d'/' -f2)
N2=$(echo $A2 | cut -d'.' -f1-3).0/$(echo $A2 | cut -d'/' -f2)

# Хостнейм
hostnamectl set-hostname isp

# Настройка сети (Interfaces)
printf "auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n\nauto eth1\niface eth1 inet static\n    address %s\n\nauto eth2\niface eth2 inet static\n    address %s\n" "$A1" "$A2" > /etc/network/interfaces

# Форвардинг
echo 1 > /proc/sys/net/ipv4/ip_forward

# Рестарт сети
systemctl restart networking

# NAT
iptables -t nat -F
iptables -t nat -A POSTROUTING -s "$N1" -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$N2" -o eth0 -j MASQUERADE

# Сохранение правил
mkdir -p /root
iptables-save > /root/rules

# Автозагрузка (Cron)
echo "@reboot root /sbin/iptables-restore < /root/rules" > /etc/cron.d/iptables_restore

# Строка 49: Разделяем команды, чтобы не было конфликтов
apt-get update
apt-get install -y tzdata
timedatectl set-timezone Europe/Moscow

echo "Done"
