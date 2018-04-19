#! /bin/bash
#
#
#
# Пример файла vm2.config:
# INTERNAL_IF="ens3"
# MANAGEMENT_IF="ens4"
# VLAN=278
# APACHE_VLAN_IP=ZZ.ZZ.ZZ.ZZ/24
# INTERNAL_IP=10.0.0.2/24
# GW_IP=10.0.0.1

CONF_FILE="${0%sh}config"

if test -r $CONF_FILE; then
   . $CONF_FILE
else
   echo 'Config file not found' >&2
   exit 1
fi

echo -e "$INTERNAL_IF\n$MANAGEMENT_IF\n$VLAN\n$APACHE_VLAN_IP\n$INTERNAL_IP\n$GW_IP"
