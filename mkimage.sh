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
BOOTPART_MiB=512
SUITE=stretch
TYPE=sd

while getopts "b:s:t:" opt; do
	case $opt in
		b)
			BOOTPART_MiB=$OPTARG
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
apt-get update
apt-get install -y git parted dosfstools e2fsprogs debootstrap
apt-get -t experimental -y install u-boot-exynos

# Get first stages of bootloader. (BL1 must be signed by Hardkernel,
# and TZSW comes without source anyway, so we can't build these ourselves)
# This is the only part that doesn't strictly need root.
if [ ! -d u-boot ]; then
	git clone https://github.com/hardkernel/u-boot -b odroidxu3-v2012.07
fi

if [ "$TYPE" != "mmcbootonly" ]; then
	# Partition the device.
	parted ${DEVICE} mklabel msdos
	parted ${DEVICE} mkpart primary fat32 2MiB $(( BOOTPART_MiB + 2 ))MiB
	parted ${DEVICE} set 1 boot on
	parted ${DEVICE} mkpart primary ext4 $(( BOOTPART_MiB + 2))MiB 100%

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

# And the main filesystem.
ROOT_PART=${DEVICE_STEM}2
mkfs.ext4 -O ^metadata_csum ${ROOT_PART}

# Mount the filesystem and debootstrap into it.
mkdir -p /tmp/xu4/
mount ${ROOT_PART} /tmp/xu4 -o rw,relatime,data=ordered
mkdir /tmp/xu4/boot/
mount ${BOOT_PART} /tmp/xu4/boot -o rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro
debootstrap --include=linux-image-armmp-lpae,grub-efi-arm,locales,sudo,openssh-server,screen,ca-certificates,ncurses-term --arch armhf ${SUITE} /tmp/xu4 "$@"

mount proc /tmp/xu4//proc -t proc -o nosuid,noexec,nodev
mount sys /tmp/xu4//sys -t sysfs -o nosuid,noexec,nodev,ro
mount udev /tmp/xu4//dev -t devtmpfs -o mode=0755,nosuid
mount devpts /tmp/xu4//dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
mount shm /tmp/xu4//dev/shm -t tmpfs -o mode=1777,nosuid,nodev
mount run /tmp/xu4//run -t tmpfs -o nosuid,nodev,mode=0755
mount tmp /tmp/xu4//tmp -t tmpfs -o mode=1777,strictatime,nodev,nosuid

# Enable persistent MAC address with systemd.link.
cat <<EOF > /tmp/xu4/etc/systemd/network/10-eth0.link
[Match]
OriginalName=eth0

[Link]
MACAddress=00:1E:06:$(od -tx1 -An -N3 /dev/random|awk '{print toupper($1), toupper($2), toupper($3)}'|tr \  :)
EOF

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /tmp/xu4 dpkg --configure -a

# Enable security updates, and apply any that might be waiting.
if [ "$SUITE" != "unstable" ] && [ "$SUITE" != "sid" ]; then
	echo "deb http://security.debian.org $SUITE/updates main" >> /tmp/xu4/etc/apt/sources.list
fi
echo deb http://httpredir.debian.org/debian experimental main >> /tmp/xu4/etc/apt/sources.list
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /tmp/xu4 apt-get update
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /tmp/xu4 apt-get dist-upgrade
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /tmp/xu4 apt-get -t experimental -y install neovim
chroot /tmp/xu4 update-alternatives --set editor /usr/bin/nvim

# Create an fstab (this is normally done by partconf, in d-i).
BOOT_UUID=$( blkid -s UUID -o value ${BOOT_PART} )
ROOT_UUID=$( blkid -s UUID -o value ${ROOT_PART} )
cat <<EOF > /tmp/xu4/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${ROOT_UUID}	/         	ext4      	rw,relatime,data=ordered	0 1

UUID=${BOOT_UUID}      	/boot     	vfat      	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro	0 2

EOF

# Set a hostname.
echo odroid > /tmp/xu4/etc/hostname

# Symlink local time zone.
chroot /tmp/xu4 ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime

# Setup locale.
sed -i 's/#\s*en_US.UTF-8/en_US.UTF-8/' /tmp/xu4/etc/locale.gen
chroot /tmp/xu4 locale-gen
chroot /tmp/xu4 update-locale $(chroot /tmp/xu4 locale | sed 's/\(.\+=\).\+/\1"en_US.UTF-8"/; s/LANG=/LANG="en_US.UTF-8"/' | tr '\n' ' ')

# Setup vconsole.
cat << EOF > /tmp/xu4/etc/vconsole.conf
KEYMAP=us
FONT=lat2-16
EOF

# Setup timesyncd.
sed -i 's/#NTP=/NTP=/; s/\(NTP=.*\)\s*/\1ntp.nict.jp/' /tmp/xu4/etc/systemd/timesyncd.conf

# Work around Debian bug #824391.
echo ttySAC2 >> /tmp/xu4/etc/securetty

# Work around Debian bug #825026.
echo ledtrig-heartbeat >> /tmp/xu4/etc/modules

# Enable serial getty and verbose boot log.
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttySAC2,115200n8"'/ /tmp/xu4/etc/default/grub

# Install GRUB, chainloaded from U-Boot via UEFI.
mount --bind /dev /tmp/xu4/dev
mount --bind /proc /tmp/xu4/proc
chroot /tmp/xu4 /usr/sbin/grub-install --removable --target=arm-efi --boot-directory=/boot --efi-directory=/boot

# Get the device tree in place (we need it to load GRUB).
# flash-kernel can do this (if you also have u-boot-tools installed),
# but it also includes its own boot script (which has higher priority than
# GRUB) and just seems to lock up.
DTB=exynos5422-$(cat /proc/device-tree/compatible | tr '\0' '\n' | grep -i hardkernel | sed 's/.*,//; s/-//').dtb
cp $( find /tmp/xu4 -name $DTB ) /tmp/xu4/boot/

# update-grub does not add “devicetree” statements for the
# each kernel (not that it's copied from /usr/lib without
# flash-kernel anyway), so we need to explicitly load it
# ourselves. See Debian bug #824399.
cat <<EOF > /tmp/xu4/etc/grub.d/25_devicetree
#! /bin/sh
set -e

# Hack added by mkimage.sh when building the root image,
# to work around Debian bug #824399.
echo "echo 'Loading device tree ...'"
echo "devicetree /$DTB"
EOF
chmod 0755 /tmp/xu4/etc/grub.d/25_devicetree

# Now we can create the GRUB boot menu.
chroot /tmp/xu4 /usr/sbin/update-grub

# Remove root password, a blank password will suffice
# while setting the users up.
chroot /tmp/xu4 /usr/bin/passwd -d root

# All done, clean up.
umount /tmp/xu4/dev
umount -R /tmp/xu4
echo "All done!"
