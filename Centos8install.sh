#!/bin/bash

##########################################################
# Automated RHEL based server installation and configuration
##########################################################

# System variables
srvrname=
dbuser=
dbpasswd=
adminUser=
smbuser=
smbgrp=
bkpdir=/mnt/backup/$srvrname
# backup device
bkpdev=/dev/sdb    
ip=10.10.10.10
# find uuid of backup device for fstab entry: "sudo blkid /dev/sd?"
uuid=                         
remivrsn=remi-release-8.rpm
phpvrsn=7.4

###########################################################
#
#
#### Configure Server ####

# Set FQDN hostname
hostnamectl set-hostname $srvrname

# Add alias for root and update alias database 
echo "root:      $adminUser" >>/etc/aliases
newaliases

echo "$ip   $srvrname" >>/etc/hosts

# Set SELINUX into permissive mode and temporarily disable till end of script
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config

###########################################################
#
#
#### Install Packages ####

# Firstly, update 
dnf update -y

# Epel Repository installation
dnf install -y epel-release
dnf config-manager --set-enabled powertools
dnf install https://rpms.remirepo.net/enterprise/$remivrsn
dnf update -y

# Apache web server and security packages
dnf install -y httpd mod_ssl openssl mod_security mod_security_crs

# Mariadb install
dnf install -y mariadb-server

# Extra packages
dnf install -y lnav lm_sensors get whois bash-completion NetworkManager-wifi NetworkManager-tui smartmontools haveged goaccess

# Security packages
dnf install -y logwatch fail2ban fail2ban-systemd clamav clamav-update lynis

# create log file for fail2ban before starting up to prevent start fail
touch /var/log/fail2ban.log

# Cockpit and related packages
dnf install -y cockpit cockpit-packagekit cockpit-storaged cockpit-pcp

# PHP install
dnf module enable php:remi-$phpvrsn 
dnf install -y php php-mysqlnd php-zip php-imap php-xml php-mbstring php-intl php-pear zip unzip git composer php-ldap php-imagick php-gd


# PHPMYAdmin install and configure
# all located in /var/www/html/.  just copy it and remember to put config file in /etc/httpd/conf.d of apache server

# Postfix and Dovecot
dnf install -y postfix postfix-mysql dovecot dovecot-mysql 

# Samba
dnf install -y samba
useradd -M -s /sbin/nologin $smbuser
passwd $smbuser
smbpasswd -a $smbuser
groupadd $smbgrp
usermod -aG $smbgrp $smbuser
rsync -arv $bkpdir/etc/samba/ /etc/samba
rsync -arv $bkpdir/srv/samba/ /srv/samba
chmod -R 770 /srv/samba/*
chown -R root:$smbgrp /srv/samba/*

# Certbot 
dnf install certbot python3-certbot-apache

# Netdata for monitoring
#curl -s https://packagecloud.io/install/repositories/netdata/netdata/script.rpm.sh | sudo bash
#sudo dnf install netdata

###########################################################
#
#
#### Begin system package restoration and configuration ####

# Create holes in firewall
firewall-cmd --permanent --add-service=imap
firewall-cmd --permanent --add-service=imaps
firewall-cmd --permanent --add-service=pop3
firewall-cmd --permanent --add-service=pop3s
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --permanent --add-service=samba
#firewall-cmd --permanent --add-port=19999/tcp   #NetData
firewall-cmd --permanent --add-port=2020/tcp
firewall-cmd --permanent --add-port=587/tcp
firewall-cmd --permanent --add-port=465/tcp
firewall-cmd --reload


# Make backup directory, create fstab entry and mount the backup drive
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


#### Apache server configuration/restoration ####

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
rsync -arv $bkpdir/etc/httpd/conf.modules.d/ /etc/httpd/conf.modules.d
rsync -arv $bkpdir/etc/httpd/modsecurity.d/ /etc/httpd/modsecurity.d
rsync -arv $bkpdir/etc/httpd/conf.d/ /etc/httpd/conf.d
rsync -arv $bkpdir/var/www/ /var/www
rsync -arv $bkpdir/etc/smartmontools/smartd.conf /etc/smartmontools


#### Mariadb config ####

echo "Begin Mariadb configuration"
echo

mysql --user=root <<_EOF_
GRANT ALL PRIVILEGES ON *.* TO '$dbuser'@'localhost' IDENTIFIED BY '$dbpasswd';
_EOF_

## Gunzip latest database backup sql.gz file for each databse and restore the database

echo "Listing of backed up databases:"
echo "$(ls -I "*.log" $bkpdir/sql)"
echo "-------------------------------------"
echo "Enter name of databases seperated by spaces to restore?"
read -p 'databases: ' dbases

for dbase in $dbases
 do
DIR="$bkpdir/sql/${dbase}/"
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


#### Postfix and Dovecot configuration ####

echo "Create virtual mail dir"
mkdir /home/vmail
mkdir /home/vmail/znicholson.net

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

groupadd -g 6000 vmail
useradd -g vmail -u 6000 vmail -d /home/vmail -m

chown -R vmail:vmail /home/vmail
chown -R vmail:dovecot /etc/dovecot
chown -R -o-rwx /etc/dovecot


# miscellaneous file restoration

rsync -arv $bkpdir/home/$adminUser/ /home/$adminUser
rsync -arv $bkpdir/etc/logwatch/ /etc/logwatch
rsync -arv $bkpdir/etc/fail2ban/ /etc/fail2ban
rsync -arv $bkpdir/etc/tripwire/ /etc/tripwire
rsync -arv $bkpdir/etc/ssh/ /etc/ssh
rsync -arv $bkpdir/etc/php.ini /etc
rsync -arv $bkpdir/etc/goaccess/ /etc/goaccess
rsync -arv $bkpdir/srv/ /srv

# Webmin installation
# {
#  echo '[Webmin]'
#  echo 'name=Webmin Distribution Neutral'
#  echo '#baseurl=https://download.webmin.com/download/yum'
#  echo 'mirrorlist=https://download.webmin.com/download/yum/mirrorlist'
#  echo 'enabled=1'
# } >/etc/yum.repos.d/webmin.repo

#rpm --import http://www.webmin.com/jcameron-key.asc
#yum install -y webmin


# restore letsencrypt certificates
rsync -arv $bkpdir/etc/letsencrypt/ /etc/letsencrypt
# or run certbot certonly --apache to create new certs

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
systemctl start clamav-freshclam
systemctl enable clamav-freshclam
systemctl start haveged
systemctl enable haveged
systemctl start smb
systemctl enable smb
systemctl start nmb
systemctl enable nmb

#### Install NetData ####
#bash <(curl -Ss https://my-netdata.io/kickstart.sh)

# Restore cronjobs
rsync -arv $bkpdir/etc/cron.custom /etc
rsync -arv $bkpdir/etc/cron.daily /etc
rsync -arv $bkpdir/etc/cron.weekly /etc
crontab -u root /home/zach/repo/crontab.bak

#### RKHunter installation and update ####
dnf install -y rkhunter
rsync -arv $bkpdir/etc/rkhunter.conf /etc
rkhunter --update
rkhunter --propupd

# Install and initialize Tripwire
dnf install -y tripwire

# remove automatically generated daily check 
rm /etc/cron.daily/tripwire-check
tripwire --init
# script to update database for missing dir/files 
./tripwireupdate.sh

# enable selinux and set policies
setenforce 1
sed -i 's/SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config
setsebool -P domain_can_mmap_files 1
setsebool -P httpd_unified 1
# SELinux Automation script
semanage import <<EOF
boolean -D
login -D
interface -D
user -D
port -D
node -D
fcontext -D
module -D
ibendport -D
ibpkey -D
permissive -D
boolean -m -1 domain_can_mmap_files
boolean -m -1 httpd_unified
boolean -m -1 nis_enabled
boolean -m -1 samba_export_all_ro
boolean -m -1 samba_export_all_rw
boolean -m -1 virt_sandbox_use_all_caps
boolean -m -1 virt_use_nfs
fcontext -a -f a -t httpd_sys_content_t -r 's0' '/srv/pfxadmin'
fcontext -a -f a -t samba_share_t -r 's0' '/srv/samba'
fcontext -a -f a -t httpd_sys_rw_content_t -r 's0' 'twig'
EOF


# set persistent file types for PostfixAdmin and Samba dirs/files
semanage fcontext -a -t samba_share_t /srv/samba
semanage fcontext -a -t httpd_sys_content_t /srv/pfxadmin

# not persistant make sure /srv directory has correct file types set for PostfixAdmin and Samba
#chcon -Rv --type=samba_share_t /srv/samba
#chcon -Rv --type=httpd_sys_content_t /srv/pfxadmin 

echo "All Finished!  The computer will now reboot."

# reboot computer
reboot
