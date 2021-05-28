#!/bin/bash

##########################################################
# Automated Centos 8 server installation and configuration
##########################################################

# Set variables
srvrname=
dbuser=
dbpasswd=
adminUser=
bkpdir=/mnt/backup/$(hostname)
bkpdev=/dev/sdb
ip=10.10.10.10
# find uuid of backup device for fstab entry: "sudo blkid | grep UUID"
uuid=

###########################################################
# Begin post install configuration
###########################################################

# Set FQDN hostname
hostnamectl set-hostname $srvrname

# Add alias for root and update alias database 
echo "root:      $adminUser" >>/etc/aliases
newaliases

echo "$ip   $srvrname" >>/etc/hosts

# Set SELINUX into permissive mode and permenantly disable
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config

# Firstly, update 
dnf update -y

# Epel Repository installation
dnf install -y epel-release
dnf config-manager --set-enabled powertools
dnf install https://rpms.remirepo.net/enterprise/remi-release-8.rpm
dnf update -y

# Apache web server and security packages
dnf install -y httpd mod_ssl openssl
systemctl start httpd

# Mariadb install
dnf install -y mariadb-server
systemctl start mariadb

# Extra packages
dnf install -y lnav lm_sensors logwatch wget fail2ban fail2ban-systemd whois bash-completion NetworkManager-wifi NetworkManager-tui clamav clamav-update

touch /var/log/fail2ban.log

# Cockpit and related packages
dnf install -y cockpit cockpit-packagekit cockpit-storaged cockpit-pcp

# PHP install
dnf module enable php:remi-7.4 
dnf install -y php php-mysqlnd php-zip php-imap php-gd

# PHPMYAdmin install and configure
# all located in /var/www/html/.  just copy it and remember to put config file in /etc/httpd/conf.d of apache server

# Postfix and Dovecot
dnf install -y postfix postfix-mysql dovecot dovecot-mysql
echo "Create virtual mail dir"
mkdir /home/vmail
mkdir /home/vmail/znicholson.net
echo


# UPS battery backup software


# Firewalld setup
firewall-cmd --permanent --add-service=imap
firewall-cmd --permanent --add-service=imaps
firewall-cmd --permanent --add-service=pop3
firewall-cmd --permanent --add-service=pop3s
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --permanent --add-port=10000/tcp
firewall-cmd --permanent --add-port=19999/tcp
firewall-cmd --permanent --add-port=2020/tcp
firewall-cmd --permanent --add-port=587/tcp
firewall-cmd --permanent --add-port=465/tcp
firewall-cmd --reload


# make backup directory, create fstab entry and mount the backup drive
mkdir /mnt/backup
echo UUID=$uuid  /mnt/backup  auto  defaults  0 0 >>/etc/fstab

echo "Connect backup media at this time..."
read -p "Backup media connected (y/n)?" CONT
if [ "$CONT" = "y" ]; then
  echo "Great! Let's continue";
  mount /mnt/backup
else
  echo "Sorry, no dice.";
  exit 1;
fi

MNTPNT='/mnt/backup'
if ! mountpoint -q ${MNTPNT}/; then
	echo "Drive not mounted! Cannot continue without backup volume mounted!"
	exit 1
fi


# Apache server configuration/restoration

echo "Begin Apache server configuration"
echo

# Create default self-signed ssl certificates
if [ ! -d /etc/ssl/private ]; then
  mkdir /etc/ssl/private
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/ssl/private/localhost.key -out /etc/ssl/certs/localhost.crt

else
  echo "Key pair already exists."

fi

# restore config/dir files from backup or master server
cp /etc/httpd/conf/httpd.conf /etc/httpd/conf/httpd.conf.bak
rsync -arv $bkpdir/etc/httpd/conf/httpd.conf /etc/httpd/conf
rsync -arv $bkpdir/etc/httpd/conf.d/ /etc/httpd/conf.d
#rsync -arv $bkpdir/etc/httpd/conf.modules.d/ /etc/httpd/conf.modules.d
rsync -arv $bkpdir/var/www/ /var/www

echo

# Postfix and Dovecot configuration

echo "***Begin Postfix/Dovecot configuration***"
echo

# import config files for mail server
rsync -arv $bkpdir/etc/dovecot/ /etc/dovecot
rsync -arv $bkpdir/etc/postfix/ /etc/postfix

# configure permissions and users for postfix/dovecot
chmod 640 /etc/postfix/database-domains.cf
chmod 640 /etc/postfix/database-users.cf
chmod 640 /etc/postfix/database-alias.cf
chown root:postfix /etc/postfix/database-domains.cf
chown root:postfix /etc/postfix/database-users.cf
chown root:postfix /etc/postfix/database-alias.cf

systemctl restart postfix


groupadd -g 6000 vmail
useradd -g vmail -u 6000 vmail -d /home/vmail -m

chown -R vmail:vmail /home/vmail
chown -R vmail:dovecot /etc/dovecot
chown -R -o-rwx /etc/dovecot

echo


echo "Perform file restoration"
echo
rsync -arv $bkpdir/etc/logwatch/ /etc/logwatch
rsync -arv $bkpdir/etc/fail2ban/ /etc/fail2ban
rsync -arv $bkpdir/etc/php.ini /etc
rsync -arv $bkpdir /srv/ /srv

# Webmin installation
#{
#  echo '[Webmin]'
#  echo 'name=Webmin Distribution Neutral'
#  echo '#baseurl=https://download.webmin.com/download/yum'
#  echo 'mirrorlist=https://download.webmin.com/download/yum/mirrorlist'
#  echo 'enabled=1'
#} >/etc/yum.repos.d/webmin.repo

#rpm --import http://www.webmin.com/jcameron-key.asc
#yum install -y webmin

# Install certbot and get certificate
# add crontab entry "/usr/bin/certbot renew"
dnf install certbot python3-certbot-apache
certbot certonly --apache

# Start and enable services
systemctl start httpd
systemctl enable httpd
systemctl start mariadb
systemctl enable mariadb
systemctl start postfix
systemctl enable postfix
systemctl start dovecot
systemctl enable dovecot
systemctl start  cockpit.socket
systemctl enable cockpit.socket
systemctl start fail2ban
systemctl enable fail2ban

# Install NetData
#bash <(curl -Ss https://my-netdata.io/kickstart.sh)

# Cronjobs
rsync -arv $bkpdir/etc/cron.daily/ /etc/cron.daily
cp $bkpdir/home/zach/root.crontab /var/spool/cron
mv /var/spool/cron/root.crontab /var/spool/cron/root
chmod 600 /var/spool/cron/root

# RKHunter
dnf install -y rkhunter
rkhunter --update
rkhunter --propupd

echo "All Finished!  The computer will now reboot."

# reboot computer
reboot