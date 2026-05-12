#!/bin/bash

# Проверка прав
if [[ $EUID -ne 0 ]]; then
   echo "Запустите от имени root"
   exit 1
fi

echo "=== 1. Настройка Hostname и Сети ==="
hostnamectl set-hostname hq-srv.au-team.irpo

# Настройка интерфейса ens18 (ALT Linux style)
IFACE_DIR="/etc/net/ifaces/ens18"
mkdir -p "$IFACE_DIR"
echo "TYPE=eth" > "$IFACE_DIR/options"
echo "192.168.100.2/26" > "$IFACE_DIR/ipv4address"
echo "default via 192.168.100.1" > "$IFACE_DIR/ipv4route"
echo "nameserver 10.2.0.3" > "$IFACE_DIR/resolv.conf"

systemctl restart network
ping -c 3 192.168.100.1

echo "=== 2. Пользователь и SSH ==="
useradd sshuser -u 1010 -m 2>/dev/null
echo "sshuser:password" | chpasswd

# Настройка sudoers (wheel)
groupadd wheel 2>/dev/null
usermod -aG wheel sshuser
echo "sshuser ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# SSH Config
sed -i 's/#Port 22/Port 2024/' /etc/openssh/sshd_config
echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
echo "MaxAuthTries 2" >> /etc/openssh/sshd_config
echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config
echo "Welcome to HQ-SRV" > /etc/openssh/banner
systemctl restart sshd

echo "=== 3. Установка и настройка DNS (Bind) ==="
apt-get update && apt-get install bind bind-utils -y

# Options
cat <<EOF > /etc/bind/options.conf
listen-on { any; };
listen-on-v6 { none; };
forwarders { 77.88.8.8; };
allow-query { any; };
allow-recursion { any; };
EOF

# Zones definition
cat <<EOF >> /etc/bind/rfc1912.conf
zone "au-team.irpo" { type master; file "au-team.irpo"; };
zone "100.168.192.in-addr.arpa" { type master; file "100.168.192.in-addr.arpa"; };
EOF

# Forward Zone file
cat <<EOF > /etc/bind/zone/au-team.irpo
\$TTL 1D
@ IN SOA au-team.irpo. root.au-team.irpo. ( 2025020600 12H 1H 1W 1H )
@ IN NS au-team.irpo.
@ IN A 192.168.100.2
hq-srv IN A 192.168.100.2
hq-rtr IN A 192.168.100.1
hq-rtr IN A 192.168.100.65
hq-rtr IN A 192.168.100.81
br-rtr IN A 192.168.200.1
br-srv IN A 192.168.200.2
hq-cli IN A 192.168.100.66
EOF

# Reverse Zone file
cat <<EOF > /etc/bind/zone/100.168.192.in-addr.arpa
\$TTL 1D
@ IN SOA au-team.irpo. root.au-team.irpo. ( 2025020600 12H 1H 1W 1H )
@ IN NS au-team.irpo.
1 IN PTR hq-rtr.au-team.irpo.
65 IN PTR hq-rtr.au-team.irpo.
81 IN PTR hq-rtr.au-team.irpo.
2 IN PTR hq-srv.au-team.irpo.
66 IN PTR hq-cli.au-team.irpo.
EOF

chown root:named /etc/bind/zone/au-team.irpo /etc/bind/zone/100.168.192.in-addr.arpa
systemctl enable --now bind

echo "=== 4. RAID5 и NFS ==="
apt-get install mdadm nfs-server -y
# Создание RAID (убедитесь, что диски b,c,d пусты)
mdadm --create /dev/md0 -l 5 -n 3 /dev/sd{b,c,d} --batch
mkfs.ext4 /dev/md0
mkdir -p /raid5
UUID_MD0=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID_MD0 /raid5 ext4 defaults 0 0" >> /etc/fstab
mount -a

# Настройка NFS
mkdir -p /raid5/nfs
echo "/raid5/nfs 192.168.100.64/28(rw,sync,no_root_squash)" > /etc/exports
systemctl enable --now nfs-server
exportfs -r

echo "=== 5. Стек LAMP и Moodle ==="
apt-get install -y python3 apache2 php8.2 apache2-mod_php8.2 mariadb-server \
php8.2-mysqli php8.2-mbstring php8.2-gd php8.2-xml php8.2-curl php8.2-zip php8.2-intl php8.2-soap

systemctl enable --now httpd2 mariadb

# База данных
mysql -u root <<EOF
CREATE DATABASE moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON moodle.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
EOF

# Скачивание Moodle
wget https://download.moodle.org/download.php/direct/stable405/moodle-latest-405.tgz -O /tmp/moodle.tgz
tar -xf /tmp/moodle.tgz -C /var/www/html/
mkdir -p /var/www/moodledata
chown -R apache2:apache2 /var/www/html/moodle /var/www/moodledata

# Правка PHP.ini (путь может отличаться, проверяем 8.2)
sed -i 's/;max_input_vars = 1000/max_input_vars = 5000/' /etc/php/8.2/apache2-mod_php/php.ini

systemctl restart httpd2
