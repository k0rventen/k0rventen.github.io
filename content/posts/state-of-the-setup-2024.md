---
title: "State of the Setup 2024"
date: 2024-12-17T21:33:39+01:00
draft: true
description: "What's running at home"
tags: ["selfhosted","pi","docker"]
---

I always had some form of homelab/servers running at home. For a while I had a k8s cluster composed of 3 Raspberry pi 4(8g), then a more traditionnal x86 pc, then back on some raspberry pis.. 

I changed quite a few things this year, having moved from macOS to linux on my work computer, and my own macbook pro 2015 being replaced by an iPad for media consumption, and my linux desktop for gaming/dev etc..

I've also decided to dive into selfhosting a bit more. So here is my complete, end of 2024 setup:

- a raspberry pi 4. 8Go of RAM, a 128Go SD card. 

that's it. No need for a complex k8s cluster, with 20 VMs and 5 control planes.
The pi is running raspberry pi OS 64b lite.
I removed some stuff:
```
sudo apt purge dphys-swapfile avahi-daemon modemmanager triggerhappy --auto-remove
```
mainly dphys-swapfile, to avoid swapping to the sd card. I've had raspberry pis for a decade now, and none of my sd cards have failed, I believe in part due to not swapping on them. Moreover, the 8Go of RAM of this PI is way more than enough to run what I need.


It's running a docker compose based stack. Here is an overview:

![setup](/setup-2024/setup-2024.png)

Basically, it's my main server that handles:
- DNS & DHCP on my LAN, using [adguard](https://github.com/AdguardTeam/AdGuardHome)
- DNS for my tailscale network, using a split horizon DNS setup (again with adguard)
- Homekit integration for some very specific things using [homebridge](https://github.com/homebridge/homebridge)
- 3D printing server for my ender3v2 using [octoprint](https://github.com/OctoPrint/OctoPrint)
- centralised password management using [vaultwarden](https://github.com/dani-garcia/vaultwarden) (and bitwarden's extensions on all my devices)
- a simple network share with [samba](https://www.samba.org/)
- A digital vault for my important documents using [paperless-ngx](https://github.com/paperless-ngx/paperless-ngx)
- photo and video management with [immich](https://github.com/immich-app/immich)
- A [Magic-Mirror](https://github.com/MagicMirrorOrg/MagicMirror) server
- Local GitHub and CI/CD server using [gitea](https://github.com/go-gitea/gitea)
- basic monitoring of services, servers and such using a TIG stack [telegraf](https://github.com/influxdata/telegraf)/[influx](https://github.com/influxdata/influxdb)/[grafana](https://github.com/grafana/grafana)
- a remote [code-server](https://github.com/coder/code-server) instance for easy development on the pi
- All of the above are reverse proxied with SSL termination using [traefik](https://github.com/traefik/traefik), adn the CA/certs are generated with [minica](https://github.com/jsha/minica)

All of this is running, and the pi isn't doing much:

![usage](/setup-2024/usage.png)

Regarding the compose stack, it's all in a `services/` folder:

```
✓ pi4-carbon:~/services
> tree -L 1
.
├── adguard
├── adguard-external
├── docker-compose.yml
├── gitea
├── grafana
├── homebridge
├── immich
├── influx
├── magic-mirror
├── octoprint
├── paperless
├── samba
├── telegraf
├── traefik
└── vaultwarden
```

Each folder contains the data and configuration for that specific service, for example grafana:
```
✓ pi4-carbon:~/services
> tree -L 2 grafana/
grafana/
├── conf
│   └── grafana.ini
└── data
    ├── alerting
    ├── csv
    ├── file-collections
    ├── grafana-apiserver
    ├── grafana.db
    ├── pdf
    ├── plugins
    └── png
```

And here is an excerpt of the docker-compose:

```yaml
services:

  # Reverse proxy
  traefik:
    image: traefik:comte
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik/traefik.yaml:/etc/traefik/traefik.yaml
      - ./traefik/certs/:/certs/
      - /var/run/docker.sock:/var/run/docker.sock

  # DNS blackhole 
  # network mode because its acting as a DNS and DHCP server on the LAN
  adguard:
    image: adguard/adguardhome
    restart: always
    network_mode: host
    volumes:
    - ./adguard/conf:/opt/adguardhome/conf
    - ./adguard/data:/opt/adguardhome/work

  # Split horizon DNS for the tailscale network
  # this is configured as the DNS server for the tailnet
  # and redirects the same internal domains to the tailscale IPs
  # instead of the local ones
  adguard-external:
    image: adguard/adguardhome
    restart: always
    ports:
    - 192.168.1.1:11081:11081
    - 100.101.101.101:53:53/udp
    volumes:
    - ./adguard-external/conf:/opt/adguardhome/conf
    - ./adguard-external/data:/opt/adguardhome/work
  ...
```

Around this central server are a few components:
- the pi is part of my [tailscale](https://tailscale.com/) mesh network, and is configured to be the DNS. This allows my roaming phone/iPad to 1. get access to all my services wherever I am, like passwords, files etc.. and 2. have DNS queries go through my adblock, removing ads also on the go.
- a usb-attached SSD, for daily encrypted backup using [restic](https://github.com/restic/restic)
  The configuration is done through some systemd units:

A `mnt-backup.mount` for the disk:
  ```
  [Unit]
  Description=Restic Backup External Disk mount

  [Mount]
  What=/dev/disk/by-label/backup
  Where=/mnt/backup
  Type=ext4
  Options=defaults

  [Install]
  WantedBy=multi-user.target
  ```

A `restic.service` that starts the backup
  ```
  [Unit]
  Description=Automated backup

  After=mnt-backup.mount
  BindsTo=mnt-backup.mount
  PropagatesStopTo=mnt-backup.mount

  [Install]
  WantedBy=default.target

  [Service]
  Type=simple
  Environment="HOME=/home/coco"
  WorkingDirectory=/home/coco
  ExecStart=restic -p %d/restic -r /mnt/backup/backups backup .
  SetCredentialEncrypted=restic: \
          Whxqht+dQJax1aZeCGLxm...
  ```

And a `restic.timer` that calls the service
  ```
  [Unit]
  Description=Run backup every day at 2 AM
  [Timer]
  OnCalendar=02:00
  [Install]
  WantedBy=timers.target
  ```

I've also configured a rpi with a hard drive at my parent's, also part of my tailnet. This is for a remote encrypted backup, using restic as well. Same setup, but the units are a bit different, with a `restic-offsite.service`:
  ```
  [Unit]
  Description=Automated backup
  Wants=network.target
  After=network-online.target

  [Install]
  WantedBy=default.target

  [Service]
  Type=oneshot
  Environment="HOME=/home/coco"
  WorkingDirectory=/home/coco

  ExecStart=ssh pi@100.64.95.65 sudo systemctl start mnt-backup.mount
  ExecStart=restic -p %d/restic -r sftp:pi@100.64.95.65:/mnt/backup/backups backup .
  ExecStart=ssh pi@100.64.95.65 sudo systemctl stop mnt-backup.mount

  SetCredentialEncrypted=restic: \
          Whxqht+dQJax...
  ```
And a `restic-offsite.timer`:
  ```
  [Unit]
  Description=Run external backup every day at 3 AM
  [Timer]
  OnCalendar=*-*-* 03:00
  [Install]
  WantedBy=timers.target
  ```

On the receiving Pi, i have a similar `mnt-backup.mount` that mounts the usb hdd when needed.
The `SetCredentialEncrypted` value is created using `systemd-ask-password -n | systemd-creds encrypt --name=restic -p - -`.

And that's pretty much it. Some automation are handled through Gitea Actions, using a schedule:
```
on:
  schedule:
    - cron: '30 10 * * 1-5'

jobs:
  run_on_schedule:
    runs-on: ubuntu-latest
    steps:
      - name: Pull image and run 
        run: |
          do stuff
```

And a final automated thing is the badging at $work, which is triggered through a iOS Shortcut, that enables tailscale on my phone, uses the 'Run script over SSH' to start a playwright python script on my server to log and clock in.


Finally, a look at my Grafana dashboard. The monitoring part isn't really what i'm interested in, i mostly glance at it to spot something out of the ordinary, but I've configured some shortcuts for the most used services up top:

![dashboard](/setup-2024/dash.png)

We'll see what changes in 2025 ! Happy new year !