# apfs-reseal

This is a script that can be used to restore and reseal the rootfs on checkm8 devices on iOS 15 and above if you recovery loop due to the SSV seal breaking.

## Notes
* This script currently requires macOS to work fully automatically. If you are using Linux, you'll have to get me or someone else to prepare a zip for you for now. Full Linux support is being worked on.

## Prerequisites

### macOS
```
sudo xcode-select --install

sudo xcodebuild -license accept

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew tap esolitos/ipa

brew install esolitos/ipa/sshpass libimobiledevice jq python3

sudo python3 -m pip install pyimg4 remotezip

sudo curl -Lo /usr/local/bin/irecovery https://github.com/palera1n/palera1n/blob/legacy/binaries/Darwin/irecovery

sudo chmod +x /usr/local/bin/irecovery

sudo curl -Lo /usr/local/bin/palera1n https://github.com/palera1n/palera1n/releases/download/v2.0.0-beta.5/palera1n-macos-universal

sudo chmod +x /usr/local/bin/palera1n

git clone https://github.com/0xallie/apfs-reseal

cd apfs-reseal

./apfs_reseal.command
```

### Linux
palen1x will **not** work for this. You need full Linux with internet access. Installed Linux is preferred, live USB may be problematic unless you have 8 GB+ RAM or you clone the script to your Windows disk.

The following commands assume a Debian/Ubuntu-based Linux distro. If running from a live USB, run `sudo add-apt-repository universe` first. For other Linux distros, you may have to replace the `apt` commands with something else.

```
sudo apt update

sudo apt install -y expect gawk git jq libimobiledevice-utils openssh-client python3 python3-pip sshpass

sudo python3 -m pip install pyimg4 remotezip

sudo wget https://github.com/palera1n/palera1n/blob/legacy/binaries/Linux/irecovery -O /usr/local/bin/irecovery

sudo chmod +x /usr/local/bin/irecovery

sudo wget https://github.com/palera1n/palera1n/releases/download/v2.0.0-beta.5/palera1n-linux-x86_64 -O /usr/local/bin/palera1n

sudo chmod +x /usr/local/bin/palera1n

git clone https://github.com/0xallie/apfs-reseal

cd apfs-reseal

wget <link you were given>

unzip *.zip

sudo ./apfs_reseal.command
```
