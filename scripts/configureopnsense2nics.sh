#!/bin/sh

set -x
# Script Params
# $1 = OPNScriptURI
# $2 = OpnVersion
# $3 = WALinuxVersion
# $4 = Trusted Nic subnet prefix - used to get the gw

if [ "$(id -u)" != "0" ]; then
	echo "Must be root." >&2
	exit 1
fi

fetch $1config.xml
fetch $1get_nic_gw.py
gwip=$(python get_nic_gw.py $4)
sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" config.xml
cp config.xml /usr/local/etc/config.xml

# 1. Package to get root certificate bundle from the Mozilla Project (FreeBSD)
# 2. Install bash to support Azure Backup integration
env IGNORE_OSVERSION=yes
pkg bootstrap -f -y; pkg update -f
env ASSUME_ALWAYS_YES=YES pkg install ca_root_nss && pkg install -y bash

# Permit Root Login
sed -i "" 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config

# OPNSense Bootstrap

URL="https://github.com/opnsense/core/archive"
WORKDIR="/tmp/opnsense-bootstrap"
RELEASE="$2"

DO_ABI="-a ${RELEASE}"
DO_QUICK=
DO_BARE=
DO_TYPE=
DO_YES="-y"

FBSDNAME=$(uname -s)
if [ "${FBSDNAME}" != "FreeBSD" ]; then
	echo "Must be FreeBSD." >&2
	exit 1
fi

FBSDARCH=$(uname -p)
if [ "${FBSDARCH}" != "amd64" ]; then
	echo "Must be amd64 architecture." >&2
	exit 1
fi

FBSDVER=$(uname -r | colrm 4)
if [ "${FBSDVER}" != "13." ]; then
	echo "Must be a FreeBSD 13 release." >&2
	exit 1
fi

if [ -z "${DO_QUICK}" ]; then
	echo "This utility will attempt to turn this installation into the latest"
	echo "OPNsense ${RELEASE} release.  All packages will be deleted, the base"
	echo "system and kernel will be replaced, and if all went well the system"
	echo "pls manually reboot."
	echo
fi

rm -rf /usr/local/etc/pkg

rm -rf "${WORKDIR:?}"/*
mkdir -p ${WORKDIR}

export ASSUME_ALWAYS_YES=yes

SUBFILE="stable/${RELEASE}"
SUBDIR="stable-${RELEASE}"

fetch -o ${WORKDIR}/core.tar.gz "${URL}/${SUBFILE}.tar.gz"
tar -C ${WORKDIR} -xf ${WORKDIR}/core.tar.gz

if [ -z "${DO_BARE}" ]; then
	if pkg -N; then
		pkg unlock -a
		pkg delete -fa
	fi
	rm -f /var/db/pkg/*
fi

make -C ${WORKDIR}/core-${SUBDIR} bootstrap DESTDIR= CORE_ABI="${DO_ABI#"-a "}"

if [ -z "${DO_TYPE}" ]; then
	DO_TYPE="-t $(make -C ${WORKDIR}/core-${SUBDIR} -v CORE_NAME)"
fi

if [ -z "${DO_BARE}" ]; then
	pkg bootstrap
	pkg install "${DO_TYPE#"-t "}"
	echo "${RELEASE}" > /usr/local/opnsense/version/pkgs

	# beyond this point verify everything
	unset SSL_NO_VERIFY_PEER

	opnsense-update -bkf
fi

# Add Azure waagent
fetch https://github.com/Azure/WALinuxAgent/archive/refs/tags/v$3.tar.gz
tar -xvzf v$3.tar.gz
cd WALinuxAgent-$3/
python3 setup.py install --register-service --lnx-distro=freebsd --force
cd ..

# April 2024 Fixes - Create missing directories to resolve configureopnsense.sh failures
mkdir -p /usr/local/opnsense/service/conf
mkdir -p /usr/local/etc/rc.syshook.d/start

# Fix waagent by replacing configuration settings
ln -s /usr/local/bin/python3.9 /usr/local/bin/python
##sed -i "" 's/command_interpreter="python"/command_interpreter="python3"/' /etc/rc.d/waagent
##sed -i "" 's/#!\/usr\/bin\/env python/#!\/usr\/bin\/env python3/' /usr/local/sbin/waagent
sed -i "" 's/ResourceDisk.EnableSwap=y/ResourceDisk.EnableSwap=n/' /etc/waagent.conf
fetch $1actions_waagent.conf
cp actions_waagent.conf /usr/local/opnsense/service/conf/actions.d

# Installing bash - This is a requirement for Azure custom Script extension to run
# OPNsense removes it during bootstrap
pkg install -y bash

# Remove wrong route at initialization
cat > /usr/local/etc/rc.syshook.d/start/22-remoteroute <<EOL
#!/bin/sh
route delete 168.63.129.16
EOL
chmod +x /usr/local/etc/rc.syshook.d/start/22-remoteroute

#Adds support to LB probe from IP 168.63.129.16
# Add Azure VIP on Arp table
echo # Add Azure Internal VIP >> /etc/rc.conf
echo static_arp_pairs=\"azvip\" >>  /etc/rc.conf
echo static_arp_azvip=\"168.63.129.16 12:34:56:78:9a:bc\" >> /etc/rc.conf
# Makes arp effective
service static_arp start
# To survive boots adding to OPNsense Autorun/Bootup:
echo service static_arp start >> /usr/local/etc/rc.syshook.d/start/20-freebsd

# Reset WebGUI certificate
echo #\!/bin/sh >> /usr/local/etc/rc.syshook.d/start/94-restartwebgui
echo configctl webgui restart renew >> /usr/local/etc/rc.syshook.d/start/94-restartwebgui
echo rm /usr/local/etc/rc.syshook.d/start/94-restartwebgui >> /usr/local/etc/rc.syshook.d/start/94-restartwebgui
chmod +x /usr/local/etc/rc.syshook.d/start/94-restartwebgui
