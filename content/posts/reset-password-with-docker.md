---
title: "Reset a lost account password using docker"
date: 2023-08-09
description: "thx god I gave my account docker socket access"
tags: ["docker","linux","security"]
---


## Story time 

A funny thing happened today. 

A remote Raspberry Pi deployed a few years back for $client was having issues connecting with another system. 
When setting up the Pi, I thought of sharing my ssh key from my laptop so I could SSH into it passwordless-style.

But it didn't occured to younger (and stupider apparently) me to save the password for that account somewhere.
And on that system (and generally on Debian I believe), standard accounts are in the sudo group, but not with passwordless access, meaning you can run _sudo_ but you have to enter your session's password.

So here I am, without my own password, having to perform `sudo` enabled commands:

```
coco@insight-probe-pop:/$ sudo timedatectl show-timesync
[sudo] password for coco: 
Sorry, try again.
[sudo] password for coco: 
Sorry, try again.
[sudo] password for coco: 
sudo: 3 incorrect password attempts
coco@insight-probe-pop:/$ fjeziofgjizrejfgzr
```

No f*ckin idea of what the password is. Younger me was _smart_ and surely used a randomly generated password, "for the sake of security", obviously. 

I was preparing my email to $client, creating some subtle excuses, when I realized that the Pi was running docker containers.
And my account was able to run `docker` commands, because back when setting the system up, I also added myself to the docker group using `usermod -aG docker $USER` (on that, it's not recommended, see below on what should be done now using rootless setups). 

And through docker you can run privileged containers, _right_ ?  Running as root, _right_ ? And mount _host files_ into a container ?

**SO** if I could launch a privileged container, _and_ have a user with uid=0, _and_ mount the `/etc/passwd` file in it, could it be possible to change my password using `passwd` ?

Only one way to find out:

```
# start a container mapping the passwd file
docker run -it --privileged -v /etc/passwd:/etc/passwd debian
root@555b0af3924a:/#

# okay the file is here
root@555b0af3924a:/# ls -alh /etc/passwd
-rw-r--r-- 1 root root 1.3K Jun 12  2020 /etc/passwd

# use the container's passwd binary to change the host's passwd file
root@555b0af3924a:/# passwd coco
New password: 
Retype new password: 
passwd: password updated successfully
root@555b0af3924a:/#
exit
```

And now if I try again from my account on that machine:

```
coco@insight-probe-pop:/$ sudo echo boom
[sudo] password for coco: 
boom
```

__GOD DAMN IT WORKS !!__

I still haven't figured out if that was a 200IQ move, or just fixing a previous -200IQ move.

But I was then able to fix the problem and sent a happy email.
Also current me learned something and saved that password somewhere.
Today's a good day.

_Note: A lot changed since setting up this system regarding docker and how it handles root access. It even has a *rootless* mode (doc [here](https://docs.docker.com/engine/security/rootless/)), and the same goes for podman ([doc](https://rootlesscontaine.rs/getting-started/podman/)). Also giving non-admin users access to the docker daemon isn't a bright idea. Shame on younger me. But also thanks younger me, without that mistake I would still be figuring out how to regain access to that system._
