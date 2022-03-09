---
title: "Remote Docker"
date: 2021-07-11
description: "using a TCP & UNIX sockets and SSH forwarding"
tags: ["docker"]
---

## what & why 

If you want to control a docker instance (the docker daemon) which is not your machine, you can expose it as a TCP socket (instead of a traditionnal UNIX socket) and connect to it remotely using the docker client. We'll also use SSH forwarding to secure the connection to the docker api if security is a concern.


## how

Install docker 

```
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

then edit the systemd service unit by adding the `-H tcp://0.0.0.0:2375` to the `ExecStart` options.

```
sudo systemctl edit docker.service

[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H tcp://0.0.0.0:2375 --containerd=/run/containerd/containerd.sock
```

reload & restart

```
sudo systemctl daemon-reload
sudo systemctl restart docker.service
```

FYI, the first `ExecStart=` is to _remove_ the corresponding statement from the docker.service unit file. If we omit this, systemd will complain like `Service has more than one ExecStart= setting, which is only allowed for Type=oneshot services. Refusing.`


We can check on the server that docker is indeed listening on port 2375 by running `sudo ss -tulnp | grep 2375`:

```
tcp    LISTEN  0       4096                        *:2375               *:*      users:(("dockerd",pid=11239,fd=7)) 
```

On our local machine we should now be able to do `docker -H <server_ip:2375> ps`. 

**Important note**:  using `-p` or `-v` will not forward ports/volumes on your local machine but on the server.

### ssh tunnel


Finally, if don't want to expose the bare docker API to our network, we can wrap it in a SSH tunnel !

(you can use `docker -H ssh://example.com ps` directly, but it's good to know that you can do it using ssh tunneling like a unix greybeard.)


I assume you have ssh enabled on the server, and copied your pubkeys to make the connection passwordless. If not, enable ssh then `ssh-copy-id <remote_user>@<server_ip>`.

We can also change the override we made earlier of the docker daemon, from `-H tcp://0.0.0.0:2375` to `-H tcp://127.0.0.1:2375`, so we don't expose the docker API on each interface but only the loopback. (don't forget to reload&restart).

On our local machine, we'll do `ssh -L 8375:127.0.0.1:2375 -N <remote_user>@<server_ip>`. 

- `-L` means to use the SSH connection to port forward to our port `8375` the port `127.0.0.1:2375` from the server point of view, which is its docker tcp socket. 
- `-N` means to not launch any command

You can now do `docker -H tcp://127.0.0.1:8375 ps` from our local machine, we we are now connecting through our port `8375`, which is forwarded by SSH to the port `2375` of the server.

But we we have a look at the ssh man page, we can read this for `-L`:

```
     -L [bind_address:]port:host:hostport
     -L [bind_address:]port:remote_socket
     -L local_socket:host:hostport
     -L local_socket:remote_socket
```

I was intrigued by `[bind_address:]port:remote_socket`, specifically by `remote_socket`. That would mean we can also forward unix socket. We know that on the server, the docker API is also exposed on `/var/run/docker.sock`.

let's try `ssh -L 8375:/var/run/docker.sock -N <remote_user>@<server_ip>`. We should redirect the docker unix socket on the server to our host's port `8375`. 

```
> docker -H tcp://127.0.0.1:8375 ps
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

sure enough, it works !

As a bonus point we could disable completely the use of a TCP connection now, as we are using the unix socket on the server.

