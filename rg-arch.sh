#!/bin/bash

# ip -c a
# iwctl # internet wifi
pacman -Syy

pacman --noconfirm --needed -S dialog || { echo "Error at script start: Are you sure you're running this as the root user? Are you sure you have an internet connection?"; exit; }

dialog --defaultno --title "Confirmation" --yesno "Are you sure you want to format everything and install Arch Linux?" 5 70 3>&1 1>&2 2>&3 3>&1
option=$?
if [ "$option" == "1" ]; then
    exit
fi
dialog --title "Information" --msgbox 'The Arch Linux installation is about to start!' 5 50 3>&1 1>&2 2>&3 3>&1

username=$(dialog --no-cancel --inputbox "Enter username - this will be located to the right of the @." 7 80 3>&1 1>&2 2>&3 3>&1)
hostname=$(dialog --no-cancel --inputbox "Enter hostname - this will be located to the left of the @." 7 80 3>&1 1>&2 2>&3 3>&1)
swap=$(dialog --no-cancel --inputbox "Enter swap size. Example 16G" 7 80 3>&1 1>&2 2>&3 3>&1)
aurhelper=$(dialog --no-cancel --inputbox "Enter aurhelper you want to use. Example: yay" 7 80 3>&1 1>&2 2>&3 3>&1)

pass1=$(dialog --no-cancel --passwordbox "Enter a root password." 10 60 3>&1 1>&2 2>&3 3>&1)
pass2=$(dialog --no-cancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)

while [[ "$pass1" == "" || "$pass2" == "" ]] || [[ "$pass1" != "$pass2" ]]; do
    pass1=$(dialog --no-cancel --passwordbox "Passwords do not match or are not present.\n\nEnter password again." 10 60 3>&1 1>&2 2>&3 3>&1)
    pass2=$(dialog --no-cancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
done

echo root:$pass1 | chpasswd

# localectl list-keymaps
keyboard=$(dialog --no-cancel --inputbox "Enter keyboard layout (default ro)." 7 40 3>&1 1>&2 2>&3 3>&1)
if [ "$keyboard" != "" ]; then
    loadkeys "$keyboard"
elif [ "$keybord" == "" ]; then
    loadkeys ro
fi


# 1 - Partitioning:
# nvme0n1p1 = /boot, nvme0n1p2 = SWAP, nvme0n1p3 = encrypted root
# for the SWAP partition below, try and make it a bit bigger than your RAM, for hybernating
# o , 
# /dev/nvme0n1p1    512M          EFI System
# /dev/nvme0n1p2    (the rest)    Linux Filesystem  
partition_name="$(lsblk | grep disk | grep -o '^\w*\b')"

fdisk /dev/"$partition_name" <<EOF
d

d

d

d

w
EOF

fdisk /dev/"$partition_name" <<EOF
g
n


+500M
t
1
n


+$swap
n



w
EOF

if [ "$partition_name" == "nvme0n1" ]; then
    partition_name="nvme0n1p"
fi

# 3 - Formatting the partitions:
# the first one is our ESP partition, so for now we just need to format it
mkfs.fat -F32 /dev/"$partition_name"1
mkswap /dev/"$partition_name"2
mkfs.ext4 /dev/"$partition_name"3

mount /dev/"$partition_name"3 /mnt

# Mount the EFI partition
mkdir /mnt/boot
mount /dev/"$partition_name"1 /mnt/boot

swapon /dev/"$partition_name"2

# 5 Base System and /etc/fstab
# (this is the time where you change the mirrorlist, if that's your thing)
pacstrap /mnt base base-devel linux linux-firmware linux-headers vim zsh git docker iwd intel-ucode sudo dialog #amd-ucode

# generate the fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 6 System Configuration
# Use timedatectl(1) to ensure the system clock is accurate
timedatectl set-ntp true

mv ./programs.csv /mnt/programs.csv

cat <<EOF > /mnt/after-install.sh
#!/bin/bash

# list-timezones
ln -sf /usr/share/zoneinfo/Europe/Bucharest /etc/localtime
hwclock --systohc --utc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US ISO-8859-1" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
echo "KEYMAP=ro" >> /etc/vconsole.conf
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $username.localdomain $username" >> /etc/hosts

echo $hostname > /etc/hostname

useradd -m -g users -G wheel,storage,power,docker -s /bin/zsh $hostname
echo $hostname:$pass1 | chpasswd
echo "$hostname ALL=(ALL) ALL" >> /etc/sudoers.d/$hostname
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
echo "Defaults timestamp_timeout=0" >> /etc/sudoers
echo "Defaults insults" >> /etc/sudoers

dialog --infobox "Installing \"$aurhelper\", an AUR helper..." 4 50
cd /home/$hostname
sudo -u "$hostname" git clone --depth 1 "https://aur.archlinux.org/$aurhelper.git"  >/dev/null 2>&1
cd $aurhelper
sudo -u "$hostname" makepkg -si
cd ..
rm -dR $aurhelper

cd /

while IFS="," read -r from package description
do
    if [ "$from" = "P" ]; then
        dialog --infobox "Installing \"$package\" from pacman..." 4 50
        pacman --noconfirm --needed -S "$package"
    elif [ "$from" = "A" ]; then
        dialog --infobox "Installing \"$package\" from $aurhelper..." 4 50
        sudo -u "$hostname" $aurhelper -S --noconfirm --needed "$package"
    elif [ "$from" = "G" ]; then
        echo "this is for git"
    fi
done < <(tail -n +2 programs.csv)

# 6 - fix the mkinitcpio.conf to contain what we actually need.
sed -i 's/MODULES=()/MODULES=(nvidia i915)/' /etc/mkinitcpio.conf

mkinitcpio -p linux

# Misc options
sed -i 's/#UseSyslog/UseSyslog/' /etc/pacman.conf
sed -i 's/#Color/Color \
ILoveCandy/' /etc/pacman.conf
sed -i 's/#CheckSpace/CheckSpace/' /etc/pacman.conf

refind-install --usedefault /dev/"$parition_name"1 --alldrivers
mkrlconf
vim /boot/refind_linux.conf
# remove arch related entries (usually first two)
vim /boot/EFI/BOOT/refind.conf
# search for arch linux menu entry
# replace uuid with efi partition uuid
# root=/dev/"$partition_name"1

mkdir /boot/EFI/refind/themes
git clone https://github.com/dheishman/refind-dreary.git /boot/EFI/refind/themes/refind-dreary
mv  /boot/EFI/refind/themes/refind-dreary/highres /boot/EFI/refind/themes/refind-dreary-tmp
rm -dR /boot/EFI/refind/themes/refind-dreary
mv /boot/EFI/refind/themes/refind-dreary-tmp /boot/EFI/refind/themes/refind-dreary

sed -i 's/#resolution 3/resolution 1920 1080/' /boot/EFI/refind/refind.conf
sed -i 's/#use_graphics_for osx,linux/use_graphics_for linux/' /boot/EFI/refind/refind.conf
sed -i 's/#scanfor internal,external,optical,manual/scanfor manual,external/' /boot/EFI/refind/refind.conf


systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable cups.service
systemctl enable sshd
systemctl enable avahi-daemon
systemctl enable tlp
systemctl enable reflector.timer
systemctl enable fstrim.timer
systemctl enable libvirtd
systemctl enable acpid

# Tap to click
[ ! -f /etc/X11/xorg.conf.d/40-libinput.conf ] && printf 'Section "InputClass"
        Identifier "libinput touchpad catchall"
        MatchIsTouchpad "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
	# Enable left mouse button by tapping
	Option "Tapping" "on"
EndSection' > /etc/X11/xorg.conf.d/40-libinput.conf

dialog --infobox "Getting rid of that retarded error beep sound..." 10 50
rmmod pcspkr
echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf

exit # to leave the chroot
EOF

chmod +x /mnt/after-install.sh
arch-chroot /mnt /after-install.sh

rm -rf /mnt/after-install.sh
rm -rf ./rg-arch.sh
rm -rf /mnt/programs.csv

umount -R /mnt
reboot
