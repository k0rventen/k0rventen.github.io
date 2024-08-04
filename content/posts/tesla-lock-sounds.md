---
title: "Randomized Tesla Lock Sounds using a Pi"
date: 2024-06-24
description: "A different lock sound every time"
tags : ["raspberrypi","tesla","wav","g_mass_storage","exfat"]
---

# What and why

Since the Winter 2023 Holiday Update, a new feature appeared on my model 3 Highland: you could change the lock sound to some sounds provided by Tesla, or provide your own, by putting a `LockChime.wav` file at the root of the TESLADRIVE usb key.

I've been playing with it with various sounds found here and there, but I still had to open the glovebox, take the USB key out, change the file and plug it back in.

I then realized that some raspberry pis (the Zeros W and 2 can, as the 4b)can act as a mass storage device through their usb cable. Wouldn't that be cool to change the lock sound of the car every time ? 


# How
First, let's flash a Raspberry Pi 4 with a Lite, 64b version of raspberry pi OS.

Then, we'll do the following:
- remove unused packages and services to speed up boot time
- enable the g_mass_storage kernel module (so the Tesla sees a mountable USB partition)
- create our drive image and script to handle mounting/unmounting
- test and enjoy !

Once booted, ssh/console into it, and apply the following configuration:

## remove some useless stuff:
- remove packages
  ```
  sudo apt purge triggerhappy avahi-daemon cron modemmanager dphys-swapfile --auto-remove
  ```
  This will remove packages and services that we don't need, specifically swap, avahi..

- disable unused services
  Then disable some services that can affect our boot time, mainly around BLE:
  ```
  sudo systemctl disable --now  bluetooth.service hciuart.service keyboard-setup.service systemd-timesyncd.service
  sudo systemctl mask  bluetooth.service hciuart.service keyboard-setup.service systemd-timesyncd.service
  ```

## enable the g_mass_storage kernel module
- Append to the end of `/boot/firmware/cmdline.txt`: 
  ```
  ... modules-load=dwc2,g_mass_storage
  ```
  This will load the needed kernel modules for the pi to act as a mass storage device

- At the end of `/boot/firmware/config.txt`
  ```
  [all]
  dtoverlay=dwc2
  boot_delay=0
  ```
  (You can also comment some stuff in the upper sections, like camera_auto_detect. _should_ make the boot faster, not measured)

## the actual reason we are doing this

- Create a big 32Go+ file using fallocate (Sentry Mode will not work if size < 32G)
  ```
  sudo fallocate /tesladrive -l 48G
  ```

- Create the main script  in `/usr/local/bin/tesladrive.sh`
  ```bash
  #!/bin/bash

  # mount as loop
  mkdir -p /mnt/tesladrive
  losetup  /dev/loop2 /tesladrive
  mount -t exfat -o offset=1048576,time_offset=-420 /dev/loop2 /mnt/tesladrive

  # swap the lock chime
  cp $(find /mnt/tesladrive/chimes/ -maxdepth 1 -type f | shuf -n 1) /mnt/tesladrive/LockChime.wav

  # unmount
  umount /mnt/tesladrive
  losetup -d /dev/loop2

  # g_mass_storage
  modprobe g_mass_storage file=/tesladrive stall=0
  ```
  The script is fairly simple, it is left as an exercise for the reader (and future me) to figure it out.
  The only weird thing is the `offset` argument to the mount command. This is because the device is /dev/loop2,
  but the exfat partition is actually /dev/loop2p1, which isn't starting on the same block (thx exfat).
  So to mount it, you must tell mount how much offset to the actual start of the exfat partition. 
  
  Here is what `fdisk` returns for our loopdevice:
  ```
  Disk /dev/loop2: 48 GiB, 51539607552 bytes, 100663296 sectors
  Units: sectors of 1 * 512 = 512 bytes
  Sector size (logical/physical): 512 bytes / 512 bytes
  I/O size (minimum/optimal): 512 bytes / 512 bytes
  Disklabel type: dos
  Disk identifier: 0x83f38a18

  Device       Boot Start       End   Sectors Size Id Type
  /dev/loop2p1       2048 100663295 100661248  48G  7 HPFS/NTFS/exFAT
  ```
  So to compute the offset for mount, we do `start sector` * `sector size`, in our case 2048*512=1048576

  Your values _might_ be different.


- Create a service file for it:
  The goal here is to make is start as early as possible during the boot process, hence the basic target.
  Put it in `/etc/systemd/system/tesladrive.service`
  ```
  [Unit]
  Description=Launch the tesla drive module as fast as possible
  Before=basic.target
  After=local-fs.target sysinit.target
  DefaultDependencies=no

  [Service]
  ExecStart=/home/coco/tesladrive.sh

  [Install]
  WantedBy=basic.target
  ```

  then enable the service:
  ```
  systemctl enable tesladrive
  ```
## create the fs, add your sounds and enjoy !
  Now, You can mount manually the partition and format at as exFat:
  ```
  losetup  /dev/loop2 /tesladrive
  mkfs.exfat /dev/loop2
  ```

  __Note: I had an issue where the Tesla did not recognized the partition properly, and I had to format it from the Tesla.__

  Inside, we'll create a `chimes` dir that will hold the available lock sounds.
  The script will pick one randomly and set it as the default one each time.

  Here is how the file structure should look like:
  ```
  coco@teslapi:~ $ ls /mnt/tesladrive/
  LockChime.wav  TeslaCam  chimes
  coco@teslapi:~ $ ls /mnt/tesladrive/chimes/
  90s-modem.wav           bipbip.wav         eternity.wav  ogs              pikachu.wav
  airplane-seat-belt.wav  canttouchthis.wav  hadouken.wav  pac-man-die.wav
  ```

  You can find locksounds online, for example here: https://www.notateslaapp.com/tesla-custom-lock-sounds/

  One thing to note is that the volume can be quite high on some of them. I used `sox` to reduce it for all of them, as to not be overly loud (but still funny):
  ```
  sox -v 0.3 lock.wav lock_low.wav
  ```
  (From https://stackoverflow.com/questions/21776073/reduce-volume-of-audio-file-by-percentage-value-using-sox)

  Finally, plug the Pi in the USB port in the Tesla's glovebox, select Lock sound: 'USB', then step away from the car.

  Every time the car starts up, this will start the Pi, which will swap the lock sound before mounting the partition as a mass storage for the tesla, changing the lock sound !
