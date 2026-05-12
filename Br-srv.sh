#!/bin/bash

echo "=== 1. Настройка имени и сети ==="
hostnamectl set-hostname br-srv.au-team.irpo

IFACE_DIR="/etc/net/ifaces/ens18"
mkdir -p "$IFACE_DIR"
echo "TYPE=eth" > "$IFACE_DIR/options"
echo "192.168.200.2/27" > "$IFACE_DIR/ipv4address"
echo "default via 192.168.200.1" > "$IFACE_DIR/ipv4route"
echo "nameserver 10.2.0.3" > "$IFACE_DIR/resolv.conf"

systemctl restart network

echo "=== 2. Пользователь и SSH ==="
useradd sshuser -u 1010 -m
echo "sshuser:password" | chpasswd
usermod -aG wheel sshuser
echo "sshuser ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

sed -i 's/#Port 22/Port 2024/' /etc/openssh/sshd_config
echo -e "AllowUsers sshuser\nMaxAuthTries 2\nBanner /etc/openssh/banner" >> /etc/openssh/sshd_config
echo "Authorized access only" > /etc/openssh/banner
systemctl restart sshd

echo "=== 3. Установка Samba DC ==="
apt-get update && apt-get upgrade -y
apt-get install task-samba-dc -y

# Очистка старой конфигурации
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/* /var/cache/samba/*
mkdir -p /var/lib/samba/sysvol

echo "nameserver 127.0.0.1" > /etc/resolv.conf

samba-tool domain provision --realm=au-team.irpo --domain=au-team --adminpass='P@ssw0rd' \
--dns-backend=SAMBA_INTERNAL --option="dns forwarder = 192.168.100.2" --server-role=dc --use-rfc2307

cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable --now samba

echo "=== 4. Настройка доменных пользователей и Ansible ==="
kinit administrator@AU-TEAM.IRPO <<EOF
P@ssw0rd
EOF

for i in {1..5}; do samba-tool user add "user${i}.hq" "P@ssw0rd"; done

apt-get install ansible python3 sshpass -y
mkdir -p /etc/ansible
echo "interpreter_python=/usr/bin/python3" >> /etc/ansible/ansible.cfg

# Пример файла хостов Ansible
cat <<EOF > /etc/ansible/hosts
[servers]
hq-srv ansible_ssh_user=sshuser ansible_ssh_port=2025
br-srv ansible_ssh_user=sshuser
[cli]
hq-cli ansible_ssh_user=sshuser
[eco]
hq-rtr ansible_user=netadmin ansible_password=P@ssw0rd ansible_connection=network_cli ansible_network_os=ios
br-rtr ansible_user=netadmin ansible_password=P@ssw0rd ansible_connection=network_cli ansible_network_os=ios
EOF

echo "=== 5. Docker и MediaWiki ==="
apt-get install -y docker-engine docker-compose

# Создание конфигурации MediaWiki (docker-compose.yml)
cat <<EOF > wiki.yaml
services:
  wiki:
    image: mediawiki
    ports:
      - "8080:80"
    volumes:
      # - ./LocalSettings.php:/var/www/html/LocalSettings.php
    environment:
      MEDIAWIKI_DB_HOST: mariadb
      MEDIAWIKI_DB_NAME: mediawiki
      MEDIAWIKI_DB_USER: wiki
      MEDIAWIKI_DB_PASSWORD: WikiP@ssw0rd
  mariadb:
    image: mariadb
    environment:
      MYSQL_DATABASE: mediawiki
      MYSQL_USER: wiki
      MYSQL_PASSWORD: WikiP@ssw0rd
      MYSQL_ROOT_PASSWORD: rootpassword
EOF

systemctl enable --now docker
docker compose -f wiki.yaml up -d

echo "Настройка завершена. Перейдите на http://192.168.200.2:8080 для настройки Wiki."
