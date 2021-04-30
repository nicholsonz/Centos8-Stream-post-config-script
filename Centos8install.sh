#!/bin/bash

##########################################################
# Automated Centos 7 server installation and configuration
##########################################################

# Set variables
srvrname=server.example.net
dbuser=admin
dbpasswd=yourdbpassword
adminUser=systemadministrator
bkpdir=/mnt/backup
bkpdev=/dev/sdb
ip=10.10.10.10
# find uuid of device "sudo blkid | grep UUID" and enter it here
uuid=d69f065e-e8c7-47a9-a1b1-43600635bebc



# Set FQDN hostname
hostnamectl set-hostname $srvrname

# Add alias for root and update alias database 
echo "root:      $adminUser" >>/etc/aliases
newaliases

echo "$ip   $srvrname" >>/etc/hosts

# Set SELINUX into permissive mode
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
dnf install -y lnav lm_sensors logwatch wget fail2ban fail2ban-systemd whois bash-completion NetworkManager-wifi NetworkManager-tui

touch /var/log/fail2ban.log

# Cockpit and related packages
dnf install -y cockpit cockpit-packagekit cockpit-storaged cockpit-pcp

# PHP install
dnf module enable php:remi-7.3 
dnf install -y php php-mysqlnd

# PHPMYAdmin install and configure
# all located in /var/www/html/.  just copy it and remember to put config file in /etc/httpd/conf.d of apache server

# Postfix and Dovecot
dnf install -y postfix postfix-mysql dovecot dovecot-mysql
echo "Create virtual mail dir"
mkdir /home/vmail
mkdir /home/vmail/example.net
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


# make backup directory and mount backup drive
mkdir /mnt/backup
echo UUID=$uuid  /mnt/backup  auto  noauto  0 0 >>/etc/fstab

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
rm /etc/httpd/conf.d/mod_evasive.conf
#rsync -arv $bkpdir/etc/httpd/conf.modules.d/ /etc/httpd/conf.modules.d
rsync -arv $bkpdir/var/www/ /var/www

echo

# Mariadb config

echo "Begin Mariadb configuration"
echo

mysql --user=root <<_EOF_
GRANT ALL PRIVILEGES ON *.* TO '$dbuser'@'localhost' IDENTIFIED BY '$dbpasswd';
_EOF_

#CREATE DATABASE mailloop DEFAULT CHARACTER SET utf8;
#CREATE DATABASE suitecrm DEFAULT CHARACTER SET utf8;
#CREATE DATABASE openfire DEFAULT CHARACTER SET utf8;
#CREATE DATABASE contacts DEFAULT CHARACTER SET utf8;
#CREATE DATABASE postfix DEFAULT CHARACTER SET utf8;
#_EOF_

## Gunzip latest database backup sql.gz file for each databse and restore the database

echo "Listing of backed up databases:"
echo "$(ls $bkpdir/sql)"
echo "-------------------------------------"
echo "Name of databases seperated by spaces to restore?"
read -p 'databases: ' dbases

for dbase in $dbases
 do

DIR="/mnt/backup/sql/${dbase}/"
NEWEST=`ls -tr1d "${DIR}/"*.gz 2>/dev/null | tail -1`
TODAY=$(date +"%a")

mysql --user=root -e "CREATE DATABASE $dbase DEFAULT CHARACTER SET utf8";

  if [ ! -f "*.sql" ] ; then
   gunzip -f ${NEWEST}
   mysql --user=root "$dbase" < $DIR/$TODAY.sql
else
    echo "The .sql file already exists for this $dbase"

fi
done

echo "Securing SQL installation"
mysql_secure_installation

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
rsync -arv $bkpdir/etc/php.ini /etc/

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
systemctl enable fail2ban
systemctl start fail2ban

# Install NetData
#bash <(curl -Ss https://my-netdata.io/kickstart.sh)

# Cronjobs
mkdir /etc/cron.custom

# drop in custom cron jobs
rsync -arv $bkpdir/etc/cron.custom/ /etc/cron.custom


# RKHunter
dnf install -y rkhunter
rkhunter --update
rkhunter --propupd

echo "All Finished!  The computer will now reboot."

# reboot computer
reboot
