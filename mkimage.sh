#! /bin/sh

# Install a bog-standard Debian bootable for ODROID XU3/XU4.
# Note that this will only work for SD cards; MMC devices
# have a different layout. See
# /usr/share/doc/u-boot-exynos/README.odroid.gz for more details.
#
# Note: You will need u-boot-exynos >= 2016.05~rc3+dfsg1-1,
# which at the time of writing is in experimental (it will
# probably eventually hit stretch).
#
# Beware: This will ERASE ALL DATA on the target SD card.
#
#
# Copyright 2016 Steinar H. Gunderson <steinar+odroid@gunderson.no>.
# Licensed under the GNU GPL, v2 or (at your option) any later version.

set -e
set -x

DEVICE=$1
BOOTPART_MB=$2

if [ ! -b "$DEVICE" ] || [ ! "$BOOTPART_MB" -gt 0 ]; then
	echo "Usage: $0 DEVICE BOOTPARTITION_SIZE [SUITE [OTHER_DEBOOTSTRAP_ARGS...]]"
	echo "DEVICE is an SD card device, e.g. /dev/sdb."
	exit 1
fi
shift 2

SUITE=$1
if [ -z "$SUITE" ]; then
	# Sorry, jessie won't work; the kernel doesn't support XU3/XU4.
	SUITE=stretch
else
	shift
fi

# Prerequisites.
dpkg --add-architecture armhf
apt update
apt install git parted dosfstools e2fsprogs binfmt-support qemu qemu-user-static debootstrap zerofree u-boot-exynos:armhf

# Get first stages of bootloader. (BL1 must be signed by Hardkernel,
# and TZSW comes without source anyway, so we can't build these ourselves)
# This is the only part that doesn't strictly need root.
if [ ! -d u-boot ]; then
	git clone https://github.com/hardkernel/u-boot -b odroidxu3-v2012.07
fi

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

# Put the different stages of U-Boot into the right place.
# The offsets come from README.odroid.gz.
dd if=u-boot/sd_fuse/hardkernel_1mb_uboot/bl1.bin.hardkernel of=${DEVICE} seek=1 conv=sync
dd if=u-boot/sd_fuse/hardkernel_1mb_uboot/bl2.bin.hardkernel.1mb_uboot of=${DEVICE} seek=31 conv=sync
dd if=/usr/lib/u-boot/odroid-xu3/u-boot-dtb.bin of=${DEVICE} seek=63 conv=sync
dd if=u-boot/sd_fuse/hardkernel_1mb_uboot/tzsw.bin.hardkernel of=${DEVICE} seek=2111 conv=sync

# Clear out the environment.
dd if=/dev/zero of=${DEVICE} seek=2560 count=32 bs=512 conv=sync

# Create a /boot partition. Strictly speaking, almost everything could be loaded
# from ext4, but using FAT is somehow traditional and less likely to be broken
# at any given time. (It doesn't support symlinks, though, which breaks flash-kernel,
# but we don't use that anyway.)
mkfs.vfat -F 32 ${DEVICE_STEM}1

# Put an LVM on the other partition; it's easier to deal with when expanding
# partitions or otherwise moving them around.
vgchange -a n odroid || true  # Could be left around from a previous copy of the partition.
pvcreate -ff ${DEVICE_STEM}2
vgcreate odroid ${DEVICE_STEM}2
lvcreate -l 100%FREE -n root odroid

# And the main filesystem.
mkfs.ext4 /dev/odroid/root

# Mount the filesystem and debootstrap into it.
# isc-dhcp-client is, of course, not necessarily required, especially as
# systemd-networkd is included and can do networking just fine, but most people
# will probably find it very frustrating to install packages without it.
mkdir -p /mnt/xu4/
mount /dev/odroid/root /mnt/xu4
mkdir /mnt/xu4/boot/
mount ${DEVICE_STEM}1 /mnt/xu4/boot
debootstrap --include=linux-image-armmp-lpae,grub-efi-arm,lvm2,isc-dhcp-client --foreign --arch armhf ${SUITE} /mnt/xu4 "$@"

# Run the second stage debootstrap under qemu (via binfmt_misc).
cp /usr/bin/qemu-arm-static /mnt/xu4/usr/bin/
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 /debootstrap/debootstrap --second-stage
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 dpkg --configure -a

# Enable security updates, and apply any that might be waiting.
if [ "$SUITE" != "unstable" ] && [ "$SUITE" != "sid" ]; then
	echo "deb http://security.debian.org $SUITE/updates main" >> /mnt/xu4/etc/apt/sources.list
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 apt update
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/xu4 apt dist-upgrade
fi

# Create an fstab (this is normally done by partconf, in d-i).
BOOT_UUID=$( blkid -s UUID -o value ${DEVICE_STEM}1 )
cat <<EOF > /mnt/xu4/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
/dev/odroid/root / ext4 errors=remount-ro 0 1
UUID=${BOOT_UUID} /boot vfat defaults 0 2
EOF

# Set a hostname.
echo odroid > /mnt/xu4/etc/hostname

# Work around Debian bug #824391.
echo ttySAC2 >> /mnt/xu4/etc/securetty

# Install GRUB, chainloaded from U-Boot via UEFI.
mount --bind /dev /mnt/xu4/dev
mount --bind /proc /mnt/xu4/proc
chroot /mnt/xu4 /usr/sbin/grub-install --removable --target=arm-efi --boot-directory=/boot --efi-directory=/boot

# Get the device tree in place (we need it to load GRUB).
# flash-kernel can do this (if you also have u-boot-tools installed),
# but it also includes its own boot script (which has higher priority than
# GRUB) and just seems to lock up.
cp $( find /mnt/xu4 -name exynos5422-odroidxu4.dtb ) /mnt/xu4/boot/

# update-grub does not add “devicetree” statements for the
# each kernel (not that it's copied from /usr/lib without
# flash-kernel anyway), so we need to explicitly load it
# ourselves. See Debian bug #824399.
cat <<EOF > /mnt/xu4/etc/grub.d/25_devicetree
#! /bin/sh
set -e

# Hack added by prepare.sh when building the root image,
# to work around Debian bug #824399.
echo "echo 'Loading device tree ...'"
echo "devicetree /exynos5422-odroidxu4.dtb"
EOF
chmod 0755 /mnt/xu4/etc/grub.d/25_devicetree

# Work around Debian bug #823552.
sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 loglevel=4"/' /mnt/xu4/etc/default/grub 

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
rm /mnt/xu4/usr/bin/qemu-arm-static
umount /mnt/xu4/dev
umount /mnt/xu4/proc
umount /mnt/xu4/boot
umount /mnt/xu4

# The root file system is ext4, so we can use zerofree, which is
# supposedly faster than dd-ing a zero file onto it.
zerofree -v /dev/odroid/root

vgchange -a n odroid
