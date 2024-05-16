---
title: "How to resize an LVM ext4 partition (and also non-LVM because old VMs)"
date: 2024-04-29
description: "this thing you do every 6 months and forget"
tags: ["lvm","ext4","linux","fdisk"]
---

# what & why

Every now and then, I have to resize a root partition on an LVM linux machine.

Every time, I take more time to recall what steps to do, and in which order. Is it `pvresize`, then `lvrezise`, or `lvextend` ?

Every. god. damn. time. Let's put an end to this by having the steps written down somewhere, 
so I can reference them when the 'we should increase this vm's disk' sentence is heard.

Also, how to do it on a non-LVM machine, because sometimes you encounter old, very old VMs that do not use LVM.
# how

## The LVM way

let's make some assumptions:
- you are on a fairly recent linux, with the fdisk, df, and the lvm utils installed
- LVM is already enabled for the partition you have to increase
- It's a VM and you just changed the disk's size (eg Vcenter, qemu-img..)


First, let's check on the VM if we see the new disk size using `fdisk`:
```
root@debian:~# fdisk -l
Disk /dev/vda: 30 GiB, 32212254720 bytes, 62914560 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x8b02b392

Device     Boot   Start      End  Sectors  Size Id Type
/dev/vda1  *       2048   999423   997376  487M 83 Linux
/dev/vda2       1001470 41940991 40939522 19.5G  5 Extended
/dev/vda5       1001472 41940991 40939520 19.5G 8e Linux LVM
```

Ok, so we do have a 30G disk to play with, and our linux fs is 19.5G. Due to the LVM setup, our partition is at /dev/mapper/debian--vg-root.

Here, we have two possible ways of doing things:
- we either resize the current 'Extended' partition using fdisk, and then we propagate the new size to LVM
- or we create a new partition from the available space, and add it to our LVM volumes.

If you want to use the solution 1, go down and read the [section on non-LVM resizing](#the-non-lvm-way), and apply the steps until the resize2fs. Then come back. Otherwise, tag along:

First, let's create a new partition using fdisk:

```
root@debian:~# fdisk /dev/vda

Welcome to fdisk (util-linux 2.38.1).
Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

This disk is currently in use - repartitioning is probably a bad idea.
It's recommended to umount all file systems, and swapoff all swap
partitions on this disk.

```
Now, we'll create a new partition that will use the new available space: 
```
Command (m for help): n
Partition type
   p   primary (1 primary, 1 extended, 2 free)
   l   logical (numbered from 5)
Select (default p): p
Partition number (3,4, default 3): 3
First sector (41940992-62914559, default 41940992): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (41940992-62914559, default 62914559): 

Created a new partition 3 of type 'Linux' and of size 10 GiB.

```
We'll change its type to `8e`, which is the one for LVM
```
Command (m for help): t
Partition number (1-3,5, default 5): 3
Hex code or alias (type L to list all): 8e

Changed type of partition 'Linux' to 'Linux LVM'.

Command (m for help): p
Disk /dev/vda: 30 GiB, 32212254720 bytes, 62914560 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x8b02b392

Device     Boot    Start      End  Sectors  Size Id Type
/dev/vda1  *        2048   999423   997376  487M 83 Linux
/dev/vda2        1001470 41940991 40939522 19.5G  5 Extended
/dev/vda3       41940992 62914559 20973568   10G 8e Linux LVM
/dev/vda5        1001472 41940991 40939520 19.5G 8e Linux LVM

Partition table entries are not in disk order.
```
And we write the partition table:
```
Command (m for help): w
The partition table has been altered.
Syncing disks.
```

Ok, we now have a new partition of 10G:

```
root@debian:~# fdisk -l
Disk /dev/vda: 30 GiB, 32212254720 bytes, 62914560 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x8b02b392

Device     Boot    Start      End  Sectors  Size Id Type
/dev/vda1  *        2048   999423   997376  487M 83 Linux
/dev/vda2        1001470 41940991 40939522 19.5G  5 Extended
/dev/vda3       41940992 62914559 20973568   10G 8e Linux LVM
/dev/vda5        1001472 41940991 40939520 19.5G 8e Linux LVM
```

We'll now create a new volume:
```
root@debian:~# pvcreate /dev/vda3
  Physical volume "/dev/vda3" successfully created.

root@debian:~# pvs
  PV         VG        Fmt  Attr PSize   PFree 
  /dev/vda3  debian-vg lvm2 a--   10.00g 10.00g
  /dev/vda5  debian-vg lvm2 a--  <19.52g     0 
```

We then extend our current VG with this new PV:
```
root@debian:~# vgextend debian-vg /dev/vda3
  Volume group "debian-vg" successfully extended

root@debian:~# vgs
  VG        #PV #LV #SN Attr   VSize   VFree 
  debian-vg   2   2   0 wz--n- <29.52g 10.00g
```

And finally, we extend the LV of our root partition with this new PV:
```
root@debian:~# lvextend /dev/debian-vg/root /dev/vda3
  Size of logical volume debian-vg/root changed from 18.56 GiB (4752 extents) to 28.56 GiB (7312 extents).
  Logical volume debian-vg/root successfully resized.

root@debian:~# lvs
  LV     VG        Attr       LSize   Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  root   debian-vg -wi-ao----  28.56g                                                    
  swap_1 debian-vg -wi-ao---- 980.00m                                                    
```

We can now resize the filesystem of the VG using `resize2fs`:
```
root@debian:~# resize2fs /dev/mapper/debian--vg-root 
resize2fs 1.47.0 (5-Feb-2023)
Filesystem at /dev/mapper/debian--vg-root is mounted on /; on-line resizing required
old_desc_blocks = 3, new_desc_blocks = 4
The filesystem on /dev/mapper/debian--vg-root is now 7487488 (4k) blocks long.
```

A final check to verify that our fs takes all the space:
```
root@debian:~# df -h
Filesystem                   Size  Used Avail Use% Mounted on
udev                         961M     0  961M   0% /dev
tmpfs                        197M  632K  197M   1% /run
/dev/mapper/debian--vg-root   28G  1.6G   26G   6% /
tmpfs                        984M     0  984M   0% /dev/shm
tmpfs                        5.0M     0  5.0M   0% /run/lock
/dev/vda1                    455M   98M  333M  23% /boot
tmpfs                        197M     0  197M   0% /run/user/1000
```

And we're done !


## The non LVM way

Disclaimer, this only works if the partition you intend to extend is the last one on the disk.

If you read the section on LVM, then the procedure is the same, but without the LVM stuff:
- we use fdisk to delete, extend, write the new partition,
- we resize the fs accordingly
- tadaa it's done.


Ok first, check the disk listing:
```
coco@buntuvm:~$ sudo fdisk -l
...
Disk /dev/vda: 35 GiB, 37580963840 bytes, 73400320 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: 42E119A3-9BE7-482B-AA89-803A5A7BFDAB

Device     Start      End  Sectors Size Type
/dev/vda1   2048     4095     2048   1M BIOS boot
/dev/vda2   4096 52426751 52422656  25G Linux filesystem
```

Our /dev/vda2 is where our root partition is, and is 25Gig. But the disk is 35Gig, meaning he can extend the partition by around 10 Gig.

If we confirm using df, we cam see that our filesystem reports a Size of 25G.
```
coco@buntuvm:~$ sudo df -h
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           392M  1.6M  391M   1% /run
/dev/vda2        25G  8.9G   15G  39% /
tmpfs           2.0G     0  2.0G   0% /dev/shm
tmpfs           5.0M  8.0K  5.0M   1% /run/lock
tmpfs           392M  108K  392M   1% /run/user/1000
```

So now we'll use fdisk on our disk (the whole disk, not the partition)

```
coco@buntuvm:~$ sudo fdisk /dev/vda

Welcome to fdisk (util-linux 2.39.3).
Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

GPT PMBR size mismatch (52428799 != 73400319) will be corrected by write.
The backup GPT table is not on the end of the device. This problem will be corrected by write.
This disk is currently in use - repartitioning is probably a bad idea.
It's recommended to umount all file systems, and swapoff all swap
partitions on this disk.

```
We can use 'p' to print the partition table:
```
Command (m for help): p

Disk /dev/vda: 35 GiB, 37580963840 bytes, 73400320 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: 42E119A3-9BE7-482B-AA89-803A5A7BFDAB

Device     Start      End  Sectors Size Type
/dev/vda1   2048     4095     2048   1M BIOS boot
/dev/vda2   4096 52426751 52422656  25G Linux filesystem
```
Now, we'll delete the partition number 2 (the Linux filesystem one).
Note that this is 'safe' because we are not actually deleting the partition, but rather the information about where the partition starts and where it ends.

```
Command (m for help): d
Partition number (1,2, default 2): 2

Partition 2 has been deleted.
```

And now, we'll recreate the partition, with the same start sector, but fdisk will extend the end to the last available sector on our disk, which is '10G further' than before.

```
Command (m for help): n
Partition number (2-128, default 2): 
First sector (4096-73400286, default 4096): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (4096-73400286, default 73398271): 

Created a new partition 2 of type 'Linux filesystem' and of size 35 GiB.
Partition #2 contains a ext4 signature.

Do you want to remove the signature? [Y]es/[N]o: n

```
If we print the partition table again, we can see that our second partition is now 35G in size.
```
Command (m for help): p

Disk /dev/vda: 35 GiB, 37580963840 bytes, 73400320 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: 42E119A3-9BE7-482B-AA89-803A5A7BFDAB

Device     Start      End  Sectors Size Type
/dev/vda1   2048     4095     2048   1M BIOS boot
/dev/vda2   4096 73398271 73394176  35G Linux filesystem
```

Finally, we do not forget to write our changes to the disk:
```
Command (m for help): w
The partition table has been altered.
Syncing disks.
```


Great. Now the disk has been resized, but the filesystem doesn't know it yet. If we rerun df, we'll see the same 25G listed:
```
coco@buntuvm:~$ sudo df -h
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           392M  1.6M  391M   1% /run
/dev/vda2        25G  8.9G   15G  39% /
tmpfs           2.0G     0  2.0G   0% /dev/shm
tmpfs           5.0M  8.0K  5.0M   1% /run/lock
tmpfs           392M  108K  392M   1% /run/user/1000
```

To fix that, we'll use `resize2fs` that can extend a given ext4 partition. Here, we'll give it the partition path:

```
coco@buntuvm:~$ sudo resize2fs /dev/vda2
resize2fs 1.47.0 (5-Feb-2023)
Filesystem at /dev/vda2 is mounted on /; on-line resizing required
old_desc_blocks = 4, new_desc_blocks = 5
The filesystem on /dev/vda2 is now 9174272 (4k) blocks long.

```

And if we check the output of df again, we now have 35G to play with !
```
coco@buntuvm:~$ sudo df -h
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           392M  1.6M  391M   1% /run
/dev/vda2        35G  8.9G   24G  28% /
tmpfs           2.0G     0  2.0G   0% /dev/shm
tmpfs           5.0M  8.0K  5.0M   1% /run/lock
tmpfs           392M  108K  392M   1% /run/user/1000
```

Hopefully these instructions will serve me well next time (hey future me !)

Regards,
previous me