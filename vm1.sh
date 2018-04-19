#! /bin/bash
#
# Пример файла vm1.config для настройки VM1:
# EXTERNAL_IF="ens3"
# INTERNAL_IF="ens4"
# MANAGEMENT_IF="ens5"
# VLAN=278
# EXT_IP="DHCP" # или пара параметров (EXT_IP=172.16.1.1/24, EXT_GW=172.16.1.254)
# INT_IP=10.0.0.1/24
# VLAN_IP=YY.YY.YY.YY/24
# NGINX_PORT=AAAA
# APACHE_VLAN_IP=ZZ.ZZ.ZZ.ZZ

EXT_DNS='8.8.8.8'

CONF_FILE="${0%sh}config"
ETC='./etc'
ETC_NETWORK_INTERFACES="${ETC}/network/interfaces"

# FUNCTIONS

# err_exit exit_code err_message
err_exit() 
{
   echo "$2" >&2
   exit $1
}

ip2int()
{
    local a b c d
    { IFS=. read a b c d; } <<< $1
    echo $(((((((a << 8) | b) << 8) | c) << 8) | d))
}

int2ip()
{
    local ui32=$1; shift
    local ip n
    for n in 1 2 3 4; do
        ip=$((ui32 & 0xff))${ip:+.}$ip
        ui32=$((ui32 >> 8))
    done
    echo $ip
}

# netmask 24
netmask()
{
    local mask=$((0xffffffff << (32 - $1))); shift
    int2ip $mask
}

# broadcast 192.168.1.1 24
broadcast()
{
    local addr=$(ip2int $1); shift
    local mask=$((0xffffffff << (32 - $1))); shift
    int2ip $((addr | ~mask))
}

# network 192.168.1.1 24
network()
{
    local addr=$(ip2int $1); shift
    local mask=$((0xffffffff << (32 - $1))); shift
    int2ip $((addr & mask))
}


# MAIN

if test -r $CONF_FILE; then
   . $CONF_FILE
else
   echo 'Config file not found' >&2
   exit 1
fi

test \
-z "$EXTERNAL_IF" -o \
-z "$INTERNAL_IF" -o \
-z "$MANAGEMENT_IF" -o \
-z "$VLAN" -o \
-z "$EXT_IP" -o \
-z "$INT_IP" -o \
-z "$VLAN_IP" -o \
-z "$NGINX_PORT" -o \
-z "$APACHE_VLAN_IP" && err_exit 1 "Bad config file"

INT_ADDRESS="${INT_IP%/*}"
INT_CIDR_NETMASK="${INT_IP#*/}"
INT_NETMASK=$(netmask "$INT_CIDR_NETMASK")
INT_NETWORK=$(network "$INT_ADDRESS" "$INT_CIDR_NETMASK")
INT_BROADCAST=$(broadcast "$INT_ADDRESS" "$INT_CIDR_NETMASK")

VLAN_ADDRESS="${VLAN_IP%/*}"
VLAN_CIDR_NETMASK="${VLAN_IP#*/}"
VLAN_NETMASK=$(netmask "$VLAN_CIDR_NETMASK")
VLAN_NETWORK=$(network "$VLAN_ADDRESS" "$VLAN_CIDR_NETMASK")
VLAN_BROADCAST=$(broadcast "$VLAN_ADDRESS" "$VLAN_CIDR_NETMASK")

# DNS /etc/resolv.conf
echo "nameserver $EXT_DNS" >${ETC}/resolv.conf

# Hostname /etc/hostname
echo "vm1" >${ETC}/hostname

# Network /etc/network/interfaces
echo '# Created by vm1.sh script' >$ETC_NETWORK_INTERFACES

echo '# LOOPBACK_IF
auto lo
iface lo inet loopback
#' >>$ETC_NETWORK_INTERFACES

if [ "$EXT_IP" == "DHCP" ]; then
   echo "# EXTERNAL_IF via DHCP
auto "$EXTERNAL_IF"
iface "$EXTERNAL_IF" inet dhcp
#" >>$ETC_NETWORK_INTERFACES

else
   test -z "$EXT_GW" && err_exit 1 "Bad config file"
   EXT_ADDRESS="${EXT_IP%/*}"
   EXT_CIDR_NETMASK="${EXT_IP#*/}"
   EXT_NETMASK=$(netmask "$EXT_CIDR_NETMASK")
   EXT_NETWORK=$(network "$EXT_ADDRESS" "$EXT_CIDR_NETMASK")
   EXT_BROADCAST=$(broadcast "$EXT_ADDRESS" "$EXT_CIDR_NETMASK")
   echo "# EXTERNAL_IF
auto $EXTERNAL_IF
iface $EXTERNAL_IF inet static
   address $EXT_ADDRESS
   network $EXT_NETWORK
   netmask $EXT_NETMASK
   broadcast $EXT_BROADCAST
   gateway $EXT_GW
   dns-nameservers $EXT_DNS
   up route add default gw $EXT_GW $EXTERNAL_IF
#" >>$ETC_NETWORK_INTERFACES
fi

echo "# INTERNAL_IF
auto $INTERNAL_IF
iface $INTERNAL_IF inet static
   address $INT_ADDRESS
   network $INT_NETWORK
   netmask $INT_NETMASK
   broadcast $INT_BROADCAST
   up route add -net $INT_NETWORK netmask $INT_NETMASK $INTERNAL_IF
#" >>$ETC_NETWORK_INTERFACES

# Networking restart
${ETC}/init.d/networking restart

# Updating
apt-get -y update

# nginx installing
apt-get -y install nginx

# VLAN installing
apt-get -y install vlan
# 802.1q
echo "8021q" >> ${ETC}/modules
modprobe 8021q

# Certs
mkdir -p ${ETC}/ssl/certs/
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
-keyout ${ETC}/ssl/certs/root-ca.key -out ${ETC}/ssl/certs/root-ca.crt \
-subj "/C=UA/ST=Kharkiv/L=Kharkiv/O=Mirantis/CN=vm1.localdomain"
openssl rsa -in ${ETC}/ssl/certs/root-ca.key -out ${ETC}/ssl/certs/root-ca.key
# key
openssl genrsa -out ${ETC}/ssl/certs/web.key 4096
# CSR

openssl req -new -sha256 -key ${ETC}/ssl/certs/web.key \
-subj "/C=UA/ST=Kharkiv/L=Kharkiv/O=Mirantis/CN=vm1.localdomain" \
-reqexts SAN \
-config <(cat ${ETC}/ssl/openssl.cnf <(printf "[SAN]\nsubjectAltName=DNS:${EXT_IP},DNS:vm1.localdomain")) \
-out ${ETC}/ssl/web.csr

openssl x509 -req -days 365 -CA ${ETC}/ssl/certs/root-ca.crt \
 -CAkey ca.key \
 -set_serial 01 \
 -extfile <(cat ${ETC}/ssl/openssl.cnf <(printf "[SAN]\nsubjectAltName=DNS:${EXT_IP},DNS:vm1.localdomain")) \
 -extensions SAN \
 -in ${ETC}/ssl/web.csr \
 -out ${ETC}/ssl/certs/web.crt

# Firewall
type ufw &>/dev/null || apt-get -y install -y ufw
type iptables &>/dev/null || apt-get -y install -y iptables

# Forwarding
# DEFAULT_FORWARD_POLICY="ACCEPT"
cat ${ETC}/default/ufw > ${ETC}/default/ufw.bak
awk '#
/DEFAULT_FORWARD_POLICY/ { print "DEFAULT_FORWARD_POLICY="ACCEPT" } 
! /DEFAULT_FORWARD_POLICY/ { print }
#' ${ETC}/default/ufw.bak >${ETC}/default/ufw
# net.ipv4.ip_forward=1
cat ${ETC}/ufw/sysctl.conf > ${ETC}/ufw/sysctl.conf.bak
awk '#
/net.ipv4.ip_forward/ { print "net.ipv4.ip_forward=1" } 
! /net.ipv4.ip_forward/ { print }
#' ${ETC}/ufw/sysctl.conf.bak >${ETC}/ufw/sysctl.conf.bak

# MASQUERADE
cp ${ETC}/ufw/before.rules ${ETC}/ufw/before.rules.bak
echo "# nat Table rules
*nat
:POSTROUTING ACCEPT [0:0]

# Forward traffic from ${INT_IP} through ${EXTERNAL_IF}.
-A POSTROUTING -s ${INT_IP} -o ${EXTERNAL_IF} -j MASQUERADE

# don't delete the 'COMMIT' line or these nat table rules won't be processed
COMMIT
#" > ${ETC}/ufw/before.rules
cat ${ETC}/ufw/before.rules.bak >>${ETC}/ufw/before.rules

ufw allow 80/tcp
ufw allow 22/tcp
ufw allow 43/tcp
ufw disable && ufw enable

# MASQUERADE
# iptables -A FORWARD -s ${INT_IP} -o ${EXTERNAL_IF} -j ACCEPT
# iptables -A FORWARD -d ${INT_IP} -m state --state ESTABLISHED,RELATED -i ${EXTERNAL_IF} -j ACCEPT
# iptables -t nat -A POSTROUTING -s ${INT_IP} -o ${EXTERNAL_IF} -j MASQUERADE

# 
echo "# VLAN
auto ${INTERNAL_IF}.${VLAN}
iface ${INTERNAL_IF}.${VLAN} inet static
   address ${VLAN_ADDRESS}
   netmask ${VLAN_NETMASK}
   vlan-raw-device ${INTERNAL_IF}
   up route add -net $VLAN_NETWORK netmask $VLAN_NETMASK ${INTERNAL_IF}.${VLAN}
#" >>$ETC_NETWORK_INTERFACES

cat $ETC_NETWORK_INTERFACES

# Networking restart
${ETC}/init.d/networking restart

