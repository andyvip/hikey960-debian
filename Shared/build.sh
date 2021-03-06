#!/bin/bash

set -ex

cd

export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64

JOBS=2

download_rootfs() { (
    cd Downloads

    wget https://releases.linaro.org/debian/images/developer-arm64/latest/linaro-stretch-developer-20171109-88.tar.gz
    sudo tar xzvf linaro-stretch-developer-20171109-88.tar.gz > /dev/null
    sudo mv binary ../Build/rootfs
) }

download_linux() { (
    cd Downloads

    wget https://github.com/96boards-hikey/linux/archive/working-hikey960-v4.14-rc7-2017-11-03.tar.gz
    tar xzvf working-hikey960-v4.14-rc7-2017-11-03.tar.gz > /dev/null
    mv linux-working-hikey960-v4.14-rc7-2017-11-03 ../Build/linux-hikey960
) }

build_linux() { (
    cd Build/linux-hikey960

    make defconfig
    make -j$JOBS
) }

install_linux() { (
    cd Build/linux-hikey960

    # Image
    sudo cp arch/$ARCH/boot/Image ../rootfs/boot
    sudo cp arch/$ARCH/boot/dts/hisilicon/hi3660-hikey960.dtb ../rootfs/boot

    # Modules
    sudo -E make INSTALL_MOD_PATH=$PWD/../rootfs modules_install

    make clean
) }

download_grub() { (
    cd Build
    git clone https://git.savannah.gnu.org/git/grub.git --depth 1
) }

build_grub() { (
    cd Build/grub

    ./autogen.sh
    ./configure --prefix=/usr --target=aarch64-linux-gnu --with-platform=efi
    make -j$JOBS

    mkdir -p ../grub-install
    make DESTDIR=$PWD/../grub-install install
) }

download_uefi() { (
    cd Downloads

    wget https://builds.96boards.org/releases/hikey/linaro/debian/latest/boot-fat.uefi.img.gz
    gzip -d boot-fat.uefi.img.gz
    mv boot-fat.uefi.img ../Build/
) }

install_grub_uefi() { (
    cd Build

    cat > grub.config << 'EOF'
search.fs_label rootfs root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EOF

    GRUB_MODULES="boot chain configfile echo efinet eval ext2 fat font gettext gfxterm \
gzio help linux loadenv lsefi normal part_gpt part_msdos read regexp search \
search_fs_file search_fs_uuid search_label terminal terminfo test tftp time halt reboot"
    grub-install/usr/bin/grub-mkimage \
        --config grub.config \
        --dtb rootfs/boot/hi3660-hikey960.dtb \
        --directory=$PWD/grub-install/usr/lib/grub/arm64-efi \
        --output=grubaa64.efi \
        --format=arm64-efi \
        --prefix="/boot/grub" \
        $GRUB_MODULES

    sudo mount -o loop boot-fat.uefi.img loop
    sudo cp grubaa64.efi loop/EFI/BOOT
    sudo umount loop
) }

download_wifi_firmware() { (
    cd Downloads

    git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git --depth 1
    cp linux-firmware/ti-connectivity/wl18xx-fw-4.bin ../Build
) }

setup_wifi() { (
    cd Build

    sudo mkdir -p rootfs/lib/firmware/ti-connectivity
    sudo cp wl18xx-fw-4.bin rootfs/lib/firmware/ti-connectivity/

    cat << EOF | sudo tee -a rootfs/etc/network/interfaces
auto lo wlan0
iface lo inet loopback
allow-hotplug wlan0
iface wlan0 inet dhcp
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
) }

install_grub_cfg() { (
    cd Build

    cat > grub.cfg << 'EOF'
set default="0"
set timeout=30

menuentry 'Debian GNU/Linux' {
    search.fs_label rootfs root
    set root=($root)

    echo 'Loading linux-hikey960 v4.14-rc7 ...'
    linux /boot/Image console=tty0 console=ttyAMA6,115200n8 root=/dev/sdd10 rootwait rw efi=noruntime

    echo 'Loading devicetree ...'
    devicetree /boot/hi3660-hikey960.dtb
}

menuentry 'Fastboot' {
    search.fs_label boot boot_part
    chainloader ($boot_part)/EFI/BOOT/fastboot.efi
}
EOF

    sudo mkdir -p rootfs/boot/grub
    sudo mv grub.cfg rootfs/boot/grub/
) }

create_sparce_rootfs_image() { (
    cd Build

    sudo mv rootfs/home .

    cat << EOF | sudo tee -a rootfs/etc/fstab
/dev/sdd10  /      ext4 defaults,noatime    0   1
/dev/sdd13  /home  ext4 defaults,noatime    0   2
EOF

    dd if=/dev/zero of=rootfs.img bs=1M count=4688
    mkfs.ext4 -F -L rootfs rootfs.img
    sudo mount -o loop rootfs.img loop
    (
        cd rootfs
        sudo tar -cf - * | ( cd ../loop; sudo tar -xf - )
    )
    sudo umount loop
    img2simg rootfs.img rootfs.sparse.img 4096

    dd if=/dev/zero of=home.img bs=1M count=2048
    sudo mkfs.ext4 -F home.img
    sudo mount -o loop home.img loop
    (
        cd home
        sudo tar -cf - * | ( cd ../loop; sudo tar -xf - )
    )
    sudo umount loop
    img2simg home.img home.sparse.img 4096
) }

flash() { (
    dir=Shared/$(date "+%Y%m%d-%H%M%S")
    mkdir $dir

    cat << EOF
Please flash images manually:
$ cd $dir
$ sudo fastboot flash boot boot-fat.uefi.img
$ sudo fastboot flash system rootfs.uefi.img
$ sudo fastboot flash userdata home.uefi.img
EOF

    mv Build/boot-fat.uefi.img $dir/boot-fat.uefi.img
    mv Build/rootfs.sparse.img $dir/rootfs.sparse.img
    mv Build/home.sparse.img   $dir/home.sparse.img
) }

mkdir -p Downloads Build/loop

download_rootfs
download_linux
build_linux
install_linux
download_grub
build_grub
download_uefi
install_grub_uefi
download_wifi_firmware
setup_wifi
install_grub_cfg
create_sparce_rootfs_image
flash

echo "Finished successfully"
echo "Please config wpa_supplicant.conf manually"
