#! /bin/bash

# Install a bog-standard Debian bootable for ODROID XU3/XU4.
#
# Beware: This will ERASE ALL DATA on the target SD card
# or MMC partition.
#
#
# Original Work Copyright 2016 Steinar H. Gunderson <steinar+odroid@gunderson.no>.
# Derived Work Copyright 2016 Seo, Myunggyun <tki@tkism.org>.
# Licensed under the GNU GPL, v2 or (at your option) any later version.

set -e

DEVICE=
BOOTPART_MB=256
SUITE=stretch
TYPE=sd

while getopts "b:s:t:" opt; do
	case $opt in
		b)
			BOOTPART_MB=$OPTARG
			;;
		s)
			# Sorry, jessie won't work; the kernel doesn't support XU3/XU4.
			SUITE=$OPTARG
			;;
		t)
			TYPE=$OPTARG
			;;
		:)
			echo "Option -$OPTARG requires an argument."
			exit 1
			;;
	esac
done
shift $((OPTIND - 1))

DEVICE=$1
if [ ! -b "$DEVICE" ]; then
	echo "Usage: $0 [-b BOOTPARTITION_SIZE] [-s SUITE] [-t sd|mmc|mmcbootonly] DEVICE [OTHER_DEBOOTSTRAP_ARGS...]"
	echo "DEVICE is an SD card device, e.g. /dev/sdb."
	exit 1
fi
shift

if [ "$TYPE" != "sd" ] && [ "$TYPE" != "mmc" ] && [ "$TYPE" != "mmcbootonly" ]; then
	echo "Card type must be 'sd', 'mmc' or 'mmcbootonly'."
	exit 1
fi

if [ $UID != 0 ]; then
	echo "This script has to be run by root."
	exit 1
fi

set -x

# Prerequisites.
echo deb http://httpredir.debian.org/debian experimental main >> /etc/apt/sources.list
apt-get update
apt-get install git parted dosfstools e2fsprogs debootstrap zerofree
apt-get -t experimental install u-boot-exynos

# Get first stages of bootloader. (BL1 must be signed by Hardkernel,
# and TZSW comes without source anyway, so we can't build these ourselves)
# This is the only part that doesn't strictly need root.
if [ ! -d u-boot ]; then
	git clone https://github.com/hardkernel/u-boot -b odroidxu3-v2012.07
fi

if [ "$TYPE" != "mmcbootonly" ]; then
	# Partition the device.
	parted ${DEVICE} mklabel msdos
	parted ${DEVICE} mkpart primary fat32 2MB $(( BOOTPART_MB + 2 ))MB
	parted ${DEVICE} set 1 boot on
	parted ${DEVICE} mkpart primary ext2 $(( BOOTPART_MB + 2))MB 100%

	# Figure out if the partitions are of type ${DEVICE}1 or ${DEVICE}p1.
	if [ -b "${DEVICE}1" ]; then
		DEVICE_STEM=${DEVICE}
	elif [ -b "${DEVICE}p1" ]; then
		DEVICE_STEM=${DEVICE}p
	else
		echo "Could not find device files for partitions of ${DEVICE}. Exiting."
		exit 1
	fi
fi

# Put the different stages of U-Boot into the right place.
# The offsets come from /usr/share/doc/u-boot-exynos/README.odroid.gz.
if [ "$TYPE" = "sd" ]; then
	UBOOT_DEVICE=${DEVICE}
	UBOOT_OFFSET=1
elif [ "$TYPE" = "mmcbootonly" ]; then
	UBOOT_DEVICE=${DEVICE}
	UBOOT_OFFSET=0
else
	UBOOT_DEVICE=${DEVICE}boot0
	echo 0 > /sys/block/$(echo $UBOOT_DEVICE | sed 's|/dev/||')/force_ro
	UBOOT_OFFSET=0
fi
dd if=u-boot/sd_fuse/hardkernel_1mb_uboot/bl1.bin.hardkernel of=${UBOOT_DEVICE} seek=${UBOOT_OFFSET} conv=sync
dd if=u-boot/sd_fuse/hardkernel_1mb_uboot/bl2.bin.hardkernel.1mb_uboot of=${UBOOT_DEVICE} seek=$((UBOOT_OFFSET + 30)) conv=sync
dd if=/usr/lib/u-boot/odroid-xu3/u-boot-dtb.bin of=${UBOOT_DEVICE} seek=$((UBOOT_OFFSET + 62)) conv=sync
dd if=u-boot/sd_fuse/hardkernel_1mb_uboot/tzsw.bin.hardkernel of=${UBOOT_DEVICE} seek=$((UBOOT_OFFSET + 2110)) conv=sync

# Clear out the environment.
dd if=/dev/zero of=${DEVICE} seek=2560 count=32 bs=512 conv=sync

if [ "$TYPE" = "mmcbootonly" ]; then
	# The user asked us to only create the MMC boot partition, so exit.
	exit 0
fi

# Create a /boot partition. Strictly speaking, almost everything could be loaded
# from ext4, but using FAT is somehow traditional and less likely to be broken
# at any given time. (It doesn't support symlinks, though, which breaks flash-kernel,
# but we don't use that anyway.)
BOOT_PART=${DEVICE_STEM}1
mkfs.vfat -F 32 ${BOOT_PART}

# Put an LVM on the other partition; it's easier to deal with when expanding
# partitions or otherwise moving them around.
vgchange -a n odroid || true  # Could be left around from a previous copy of the partition.
pvcreate -ff ${DEVICE_STEM}2
vgcreate odroid ${DEVICE_STEM}2
lvcreate -l 100%FREE -n root odroid

# And the main filesystem.
mkfs.ext4 -O ^metadata_csum /dev/odroid/root

# Mount the filesystem and debootstrap into it.
# isc-dhcp-client is, of course, not necessarily required, especially as
# systemd-networkd is included and can do networking just fine, but most people
# will probably find it very frustrating to install packages without it.
mkdir -p /mnt/xu4/
mount /dev/odroid/root /mnt/xu4 -o rw,relatime,data=ordered
mkdir /mnt/xu4/boot/
mount ${BOOT_PART} /mnt/xu4/boot -o rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro
debootstrap --include=linux-image-armmp-lpae,grub-efi-arm,lvm2,isc-dhcp-client --arch armhf ${SUITE} /mnt/xu4 "$@"

mount proc /mnt/xu4//proc -t proc -o nosuid,noexec,nodev
mount sys /mnt/xu4//sys -t sysfs -o nosuid,noexec,nodev,ro
mount udev /mnt/xu4//dev -t devtmpfs -o mode=0755,nosuid
mount devpts /mnt/xu4//dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
mount shm /mnt/xu4//dev/shm -t tmpfs -o mode=1777,nosuid,nodev
mount run /mnt/xu4//run -t tmpfs -o nosuid,nodev,mode=0755
mount tmp /mnt/xu4//tmp -t tmpfs -o mode=1777,strictatime,nodev,nosuid

# Enable persistent MAC address with systemd.link.
cat <<EOF > /mnt/xu4/etc/systemd/network/10-eth0.link
[Match]
OriginalName=eth0

[Link]
MACAddress=00:1E:06:$(od -tx1 -An -N3 /dev/random|awk '{print toupper($1), toupper($2), toupper($3)}'|tr \  :)
EOF

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 dpkg --configure -a

# Enable security updates, and apply any that might be waiting.
if [ "$SUITE" != "unstable" ] && [ "$SUITE" != "sid" ]; then
	echo "deb http://security.debian.org $SUITE/updates main" >> /mnt/xu4/etc/apt/sources.list
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 apt-get update
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 apt-get dist-upgrade
fi

# Create an fstab (this is normally done by partconf, in d-i).
BOOT_UUID=$( blkid -s UUID -o value ${BOOT_PART} )
cat <<EOF > /mnt/xu4/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
/dev/odroid/root	/         	ext4      	rw,relatime,data=ordered	0 1

UUID=${BOOT_UUID}      	/boot     	vfat      	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro	0 2

EOF

# Set a hostname.
echo odroid > /mnt/xu4/etc/hostname

# Work around Debian bug #824391.
echo ttySAC2 >> /mnt/xu4/etc/securetty

# Work around Debian bug #825026.
echo ledtrig-heartbeat >> /mnt/xu4/etc/modules

# Enable serial getty and verbose boot log.
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttySAC2,115200n8"'/ /mnt/xu4/etc/default/grub

# Install GRUB, chainloaded from U-Boot via UEFI.
chroot /mnt/xu4 /usr/sbin/grub-install --removable --target=arm-efi --boot-directory=/boot --efi-directory=/boot

# Get the device tree in place (we need it to load GRUB).
# flash-kernel can do this (if you also have u-boot-tools installed),
# but it also includes its own boot script (which has higher priority than
# GRUB) and just seems to lock up.
DTB=exynos5422-$(cat /proc/device-tree/compatible | tr '\0' '\n' | grep -i hardkernel | sed 's/.*,//; s/-//').dtb
cp $( find /mnt/xu4 -name $DTB ) /mnt/xu4/boot/

# update-grub does not add “devicetree” statements for the
# each kernel (not that it's copied from /usr/lib without
# flash-kernel anyway), so we need to explicitly load it
# ourselves. See Debian bug #824399.
cat <<EOF > /mnt/xu4/etc/grub.d/25_devicetree
#! /bin/sh
set -e

# Hack added by mkimage.sh when building the root image,
# to work around Debian bug #824399.
echo "echo 'Loading device tree ...'"
echo "devicetree /$DTB"
EOF
chmod 0755 /mnt/xu4/etc/grub.d/25_devicetree

# Now we can create the GRUB boot menu.
chroot /mnt/xu4 /usr/sbin/update-grub

# Set the root password. (It should be okay to have a dumb one as default,
# since there's no ssh by default. Yet, it would be nice to have a way
# to ask on first boot, or better yet, invoke debian-installer after boot.)
echo root:odroid | chroot /mnt/xu4 /usr/sbin/chpasswd

# Zero any unused blocks on /boot, for better packing if we are to compress the
# filesystem and publish it somewhere. (See below for the root device.)
echo 'Please ignore the following error about full disk.'
dd if=/dev/zero of=/mnt/xu4/boot/zerofill bs=1M || true
rm -f /mnt/xu4/boot/zerofill

# All done, clean up.
umount /mnt/xu4/dev
umount -R /mnt/xu4

# The root file system is ext4, so we can use zerofree, which is
# supposedly faster than dd-ing a zero file onto it.
zerofree -v /dev/odroid/root

vgchange -a n odroid
