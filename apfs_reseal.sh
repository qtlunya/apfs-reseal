#!/bin/sh -e

trap 'killall -CONT AMPDevicesAgent AMPDeviceDiscoveryAgent iTunesHelper MobileDeviceUpdater' EXIT

for bin in aa awk idevicenterrecovery irecovery jq palera1n plutil pyimg4 pzb scp ssh sshpass; do
    if ! [ -x "$(command -v "$bin")" ]; then
        echo "[!] $bin not found. Please install it and try again." >&2
        exit 1
    fi
done

version=$1
if [ -z "$version" ]; then
    read -r -p "Enter iOS version: " version
fi

remote_cmd() {
    echo "[*] Running command: $1" >&2
    sshpass -p alpine ssh -q -o ProxyCommand='inetcat 22' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@ "$1"
}

remote_cp() {
    if [ "$1" = apfs_invert_asr_img ]; then
        echo "[*] Transferring file: $1 -> $2 (this may take up to 15 minutes)" >&2
    else
        echo "[*] Transferring file: $1 -> $2" >&2
    fi

    if scp -O /dev/null /dev/zero 2>/dev/null; then
        sshpass -p alpine scp -v -o ProxyCommand='inetcat 22' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -O "$1" root@:"$2"
    else
        sshpass -p alpine scp -v -o ProxyCommand='inetcat 22' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" root@:"$2"
    fi
}

echo '[*] Waiting for device in recovery mode'
while true; do
    devices=$(system_profiler SPUSBDataType)
    case $devices in
        *SSHRD_Script*)  # ramdisk
            echo '[*] Rebooting device in SSH ramdisk'
            remote_cmd '/usr/sbin/nvram auto-boot=false'
            remote_cmd '/sbin/reboot'
            case $version in
                16.*)
                    echo '[!] iOS 16 detected, please force reboot your device manually'
                    ;;
            esac
            ;;
        *'Product ID: 0x12a'[8ab]*)  # normal
            ideviceenterrecovery "$(idevice_id -l)"
            ;;
        *'Product ID: 0x1281'*)  # recovery
            break
            ;;
    esac
    sleep 1
done

device=$(irecovery -q | awk -F": " '$1 == "PRODUCT" { print $2 }')
boardconfig=$(irecovery -q | awk -F": " '$1 == "MODEL" { print $2 }')

echo "Detected $device ($boardconfig)"

irecovery -c 'setenv auto-boot false'
irecovery -c 'saveenv'

case $version in
    15.*)
        ramdisk_ver=15.6
        ;;
    16.[0-3]|16.[0-3].*)
        ramdisk_ver=16.0.3
        ;;
    *)
        echo 'ERROR: This scripts only supports iOS 15.0-16.3.1.' >&2
        exit 1
        ;;
esac

ipsw_url=$(curl -s https://api.appledb.dev/main.json | jq --arg device "$device" --arg version "$version" -r '[.ios[] | select(.version == $version and (.deviceMap | index($device)))][0] | .devices[$device].ipsw')

rootfs_dmg=$(curl -s "${ipsw_url%/*}"/BuildManifest.plist | sed 's,<data>,<string>,g; s,</data>,</string>,g' | plutil -convert json - -o - | jq -r --arg boardconfig "$boardconfig" '[.BuildIdentities[] | select(.Info.DeviceClass == $boardconfig)][0].Manifest.OS.Info.Path')

TMPDIR=${TMPDIR:-/var/tmp}

#rm -rf "$TMPDIR"/apfs_reseal

mkdir -p "$TMPDIR"/apfs_reseal
pushd "$TMPDIR"/apfs_reseal

if ! [ -e "$rootfs_dmg" ] && ! [ -e apfs_invert_asr_img ]; then
    pzb "$ipsw_url" -g "$rootfs_dmg"
fi
if ! [ -e "$rootfs_dmg".mtree ]; then
    pzb "$ipsw_url" -g Firmware/"$rootfs_dmg".mtree
fi
if ! [ -e "$rootfs_dmg".root_hash ]; then
    pzb "$ipsw_url" -g Firmware/"$rootfs_dmg".root_hash
fi
if ! [ -e "$rootfs_dmg".trustcache ]; then
    pzb "$ipsw_url" -g Firmware/"$rootfs_dmg".trustcache
fi

pyimg4 im4p extract -i "$rootfs_dmg".mtree -o manifest_and_db.aar
aa extract -i manifest_and_db.aar

if ! [ -e apfs_invert_asr_img ]; then
    asr -source "$rootfs_dmg" -target apfs_invert_asr_img --embed -erase -noprompt --chunkchecksum --puppetstrings
fi
rm -f "$rootfs_dmg"

if ! [ -e sshrd-script ]; then
    git clone https://github.com/0xallie/sshrd-script
fi
pushd sshrd-script
git fetch
git reset --hard origin/main
killall -STOP AMPDevicesAgent AMPDeviceDiscoveryAgent iTunesHelper MobileDeviceUpdater
palera1n --dfuhelper
./sshrd.sh "$ramdisk_ver"
./sshrd.sh boot
popd
echo '[*] Waiting for device to connect'
while ! remote_cmd 'echo connected' >/dev/null 2>&1; do
    sleep 0.1
done
echo '[*] Connected'
case $version in
    15.*)
        container=/dev/disk0s1
        ;;
    16.*)
        container=/dev/disk1
        ;;
esac
rootfs=${container}s1
remote_cmd "/sbin/apfs_deletefs $rootfs"
remote_cmd "/usr/sbin/newfs_apfs -o role=s -A -v System /dev/disk1"
remote_cmd "/usr/sbin/mount_apfs $rootfs /mnt1"
remote_cp apfs_invert_asr_img /mnt1/apfs_invert_asr_img
remote_cmd "/sbin/umount /mnt1"
remote_cmd "/usr/sbin/apfs_invert -d $container -s 1 -n apfs_invert_asr_img"
remote_cmd "/sbin/mount_tmpfs /mnt9"
remote_cp digest.db /mnt9/digest.db
remote_cp mtree.txt /mnt9/mtree.txt
remote_cp "$rootfs_dmg".root_hash /mnt9/root_hash
remote_cmd "/usr/sbin/mount_apfs $rootfs /mnt1"
remote_cmd "/usr/sbin/mtree -f /mnt9/mtree.txt -p /mnt1 -r -m /mnt9/mtree_remap.xml"
remote_cmd "/sbin/umount /mnt1"
remote_cmd "/usr/sbin/mount_apfs ${container}s6 /mnt6"
active=$(remote_cmd "/bin/cat /mnt6/active")
remote_cmd "/sbin/umount /mnt6"
remote_cmd "/usr/sbin/apfs_sealvolume -L -P -I /mnt9/root_hash -R /mnt9/mtree_remap.xml -u /mnt9/digest.db -p $rootfs"
remote_cmd "/usr/sbin/mount_apfs $rootfs /mnt1"
remote_cmd "/usr/bin/snaputil -c com.apple.os.update-$active /mnt1"
remote_cmd "/sbin/umount /mnt1"
remote_cmd "/sbin/umount /mnt9"
remote_cmd "/bin/sync"
remote_cmd "/usr/sbin/nvram auto-boot=false"
remote_cmd "/sbin/reboot"
case $version in
    15.*)
        echo 'Done! Your device will now reboot to recovery mode, and you should be able to boot tethered using palera1n.'
        ;;
    16.*)
        echo 'Done! Force reboot your device, then it will reboot to recovery mode, and you should be able to boot tethered using palera1n.'
        ;;
esac
