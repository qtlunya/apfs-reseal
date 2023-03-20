#!/bin/sh -e

if [ "$1" = debug ]; then
    debug=1
    shift
fi

remote_cmd() {
    echo "[*] Running command: $1" >&2
    sshpass -p alpine ssh -q -o ProxyCommand='inetcat 22' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@ "$1"
}

remote_cp() {
    echo "[*] Transferring file: $1 -> $2" >&2

    if scp -O /dev/null /dev/zero 2>/dev/null; then
        scp='scp -O'
    else
        scp='scp'
    fi

    expect -c 'set timeout -1' \
           -c "spawn $scp -o \"ProxyCommand=inetcat 22\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \"$1\" \"root@:$2\"" \
           -c 'expect "assword:"' \
           -c 'send "alpine\n"' \
           -c 'expect eof'
}

trap 'killall -CONT AMPDevicesAgent AMPDeviceDiscoveryAgent iTunesHelper MobileDeviceUpdater' EXIT

for bin in aa awk expect ideviceenterrecovery irecovery jq palera1n plutil pyimg4 pzb scp ssh sshpass; do
    if ! [ -x "$(command -v "$bin")" ]; then
        echo "[!] $bin not found. Please install it and try again." >&2
        exit 1
    fi
done

version=$1
if [ -z "$version" ]; then
    read -r -p "Enter your EXACT iOS version (including beta/RC): " version
fi

killall -STOP AMPDevicesAgent AMPDeviceDiscoveryAgent iTunesHelper MobileDeviceUpdater

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

echo '[*] Waiting for device in recovery or DFU mode'
while true; do
    devices=$(system_profiler SPUSBDataType)
    case $devices in
        *SSHRD_Script*)  # ramdisk
            device=$(remote_cmd "/usr/sbin/mgask ProductType")
            boardconfig=$(remote_cmd "/usr/sbin/mgask HWModelStr")

            echo "Detected $device ($boardconfig)"

            remote_cmd "/usr/sbin/nvram auto-boot=false"

            break
            ;;
        *'Product ID: 0x12a'[8ab]*)  # normal
            ideviceenterrecovery "$(idevice_id -l)"
            while ! irecovery -q >/dev/null 2>/dev/null; do
                sleep 0.1
            done
            ;;
        *'Product ID: 0x1281'*|*'Product ID: 0x1227'*)  # recovery/DFU
            palera1n --dfuhelper
            while ! irecovery -q >/dev/null 2>/dev/null; do
                sleep 0.1
            done

            device=$(irecovery -q | awk -F": " '$1 == "PRODUCT" { print $2 }')
            boardconfig=$(irecovery -q | awk -F": " '$1 == "MODEL" { print $2 }')

            echo "Detected $device ($boardconfig)"

            irecovery -c 'setenv auto-boot false'
            irecovery -c 'saveenv'

            if ! [ -e sshrd-script ]; then
                git clone https://github.com/0xallie/sshrd-script
            fi
            pushd sshrd-script
            git fetch
            git reset --hard origin/main
            if [ "$debug" -eq 1 ]; then
                bash -x ./sshrd.sh "$ramdisk_ver"
                bash -x ./sshrd.sh boot
            else
                ./sshrd.sh "$ramdisk_ver"
                ./sshrd.sh boot
            fi
            popd

            break
            ;;
    esac
    sleep 1
done

ipsw_url=$(curl -s https://api.appledb.dev/main.json | jq --arg device "$device" --arg version "$version" -r '[.ios[] | select(.version == $version and (.deviceMap | index($device)))][0] | .devices[$device].ipsw')

rootfs_dmg=$(curl -s "${ipsw_url%/*}"/BuildManifest.plist | sed 's,<data>,<string>,g; s,</data>,</string>,g' | plutil -convert json - -o - | jq -r --arg boardconfig "$boardconfig" '[.BuildIdentities[] | select(.Info.DeviceClass == $boardconfig)][0].Manifest.OS.Info.Path')

TMPDIR=${TMPDIR:-/var/tmp}

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

echo '[*] Waiting for device to connect'
while ! remote_cmd 'echo connected' >/dev/null 2>&1; do
    sleep 0.1
done
echo '[*] Connected'
remote_cmd "/sbin/umount /mnt*" || true
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
remote_cmd "/usr/sbin/mount_apfs ${container}s6 /mnt6"
active=$(remote_cmd "/bin/cat /mnt6/active")
remote_cmd "/usr/sbin/mount_apfs $rootfs /mnt1"
remote_cmd "/usr/sbin/mtree -p /mnt1 -m /mnt9/mtree_remap.xml -f /mnt9/mtree.txt -r"
remote_cmd "/sbin/umount /mnt1"
remote_cmd "/sbin/umount /mnt6"
remote_cmd "/usr/sbin/apfs_sealvolume -P -R /mnt9/mtree_remap.xml -I /mnt9/root_hash -u /mnt9/digest.db -p -s com.apple.os.update-$active $rootfs"
remote_cmd "/usr/sbin/mount_apfs $rootfs /mnt1"
remote_cmd "/sbin/umount /mnt9"
remote_cmd "/bin/sync"
remote_cmd "/usr/sbin/nvram auto-boot=true"
remote_cmd "/sbin/reboot"
case $version in
    15.*)
        echo '[*] Done! Your device should now boot up in normal mode.'
        ;;
    16.*)
        echo '[*] Done! Please force reboot your device, then it should boot up in normal mode.'
        ;;
esac
echo '[*] Press any key to exit'
read -r -s -n 1
