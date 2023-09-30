---
title: "A PYPI cache proxy to improve our CI workflows"
date: 2023-09-09
description: "it's like VTEC for `pip install` !"
tags : ["python","pip","ci","nginx"]
---


## what & why 


### a bit of context 

At $dayjob, our backend stack is 99% python based, and deployed through containers on k8s clusters. That means that a lot of time spent in our CI is downloading and installing librairies and modules from [Pypi](https://pypi.org), the Python Package Index. 

For the sake of data sovereignty and integrity, our CI workers are deployed on-prem, using Gitlab Runners. But due to the variety of projects, we are depending on hundreds of various libraries, ranging from fastapi/flask and their related libraries, to more esoteric ones like pysnmp, yang, scrapli, netmiko/paramiko..

### the problem

That leaves us with a significant amount of bandwith 'dedicated' to just downloading libraires, some of them being quite heavy (ML/CV like torch or openCV are more than 100Mb in size). And besides our CI workers, our dev envs are also generating containers to use in our test envs. And keeping up with recent versions means downloading even more. 

Our internet provider does not have a gigabit-class fiber for where we are (at least not at a reasonable price), so we are stuck on a ~100Mb/s downlink, shared across 2 companies, and dozens of employees.

_Note: While we use the docker layer system in our CI to cache layers between runs, the cache is not shared across runners, and has to be purged regularly (weekly) to avoid disk issues, lingering layers.._


This combination produce the following: In a CI stage building a container taking up 90s, the download of the libraries can some time tally up to 30, even 40 seconds. Overall, around 50% of our CI time is just downloading. 

Furthermore, It seems quite wasteful to download again and again the same package from PYPI, putting unnecessary strain on our internet connection, their infrastructure, and everything in between.

So the goal is to avoid as much as possible the re-download of packages from internet, and improve the time needed to download heavy packages.

## how

What we've deployed is a docker image that acts as a PIP Proxy on the whole LAN, caching packages as they come and serving them locally when asked again. 

This approach only required a single change in our CI workflow, which meant 0 downtime when deploying it. And everyone on the network can benefit from them if they add a new env var to their environment.

Before digging into the solution, there is some downsides to that solution:
- That adds a new potential point of failure for our CI. If for some reason the proxy isn't available, `pip install` will not redirect automatically to the default index URL, and all workflows will be broken
- The cache size can increase rapidely, so it's important to keep an eye on that before running into disk issues (leading to problem n°1)
- Developers using the proxy on a _mobile_ laptop will encounter problems when the laptop isn't on the same network as the proxy

Now onto the actual solution.

### the proxy/cache container

The docker container is a very simple nginx based image, with the following config from [this gist](https://github.com/hauntsaninja/nginx_pypi_cache/blob/master/nginx.conf):

{{< details "__nginx.conf__" >}}
```sh
# Loosely based on the following:
# (note these do not work correctly in 2023)
# https://joelkleier.com/blog/2018-04-17-pypi-temporary-cache.html
# https://gist.github.com/dctrwatson/5785638#file-nginx-conf
# It's also very easy to end up not proxying requests; tests/mitmtest.sh should help verify that
# pip installs actually avoid hitting upstream

error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

worker_processes auto;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nodelay on;
    tcp_nopush off;
    reset_timedout_connection on;
    server_tokens off;
    gzip on;
    gzip_types application/vnd.pypi.simple.v1+json;
    gzip_proxied any;
    gzip_vary on;

    log_format pypi_cache '$remote_addr - $host [$time_local] '
                          'request_time=$request_time upstream_time=$upstream_response_time '
                          'cache_status=$upstream_cache_status \t'
                          '$status "$request" $body_bytes_sent';
    access_log /dev/stdout pypi_cache buffer=64k flush=1s;
    # Log to file, can be useful for dev
    # access_log /var/log/nginx/cache.log pypi_cache buffer=64k flush=1s;

    # Cache 50G worth of packages for up to 6 months
    proxy_cache_path /var/lib/nginx/pypi levels=1:2 keys_zone=pypi:16m inactive=6M max_size=50G;

    # Having the same upstream server listed twice allegedly forces nginx to retry
    # connections and not fail the request immediately.
    upstream sg_pypi {
        server pypi.org:443;
        server pypi.org:443;
        keepalive 16;
    }
    upstream sg_pythonhosted {
        server files.pythonhosted.org:443;
        server files.pythonhosted.org:443;
        keepalive 16;
    }

    server {
        listen 80 default_server;

        proxy_cache pypi;
        proxy_cache_key $uri/$http_accept_encoding;
        proxy_cache_lock on;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

        proxy_http_version 1.1;
        proxy_ssl_server_name on;

        # sub_filter can't apply to gzipped content, so be careful about that
        add_header X-Pypi-Cache $upstream_cache_status;
        sub_filter 'https://pypi.org' $scheme://$host;
        sub_filter 'https://files.pythonhosted.org/packages' $scheme://$host/packages;
        sub_filter_once off;
        sub_filter_types application/vnd.pypi.simple.v1+json application/vnd.pypi.simple.v1+html;

        location / {
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_cache_valid any 5m;
            proxy_cache_valid 404 1m;

            proxy_set_header Host pypi.org;
            proxy_ssl_name pypi.org;
            proxy_pass https://sg_pypi;
            proxy_redirect 'https://pypi.org' $scheme://$host;
        }

        location ^~ /simple {
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_cache_valid any 5m;
            proxy_cache_valid 404 1m;

            proxy_set_header Host pypi.org;
            proxy_pass https://sg_pypi;
            proxy_redirect 'https://pypi.org' $scheme://$host;
        }

        location ^~ /packages {
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_cache_valid any 1M;
            proxy_cache_valid 404 1m;

            proxy_set_header Host files.pythonhosted.org;
            proxy_ssl_name files.pythonhosted.org;
            proxy_pass 'https://sg_pythonhosted/packages';

            proxy_redirect 'https://files.pythonhosted.org/packages' $scheme://$host/packages;
        }
    }
}
```
{{< /details >}}

The Dockerfile is simply the aforementionned conf applied on top of a Nginx container:

{{< details "__Dockerfile__" >}}
```dockerfile
FROM nginx:latest

RUN mkdir -p /var/lib/nginx/pypi/ /var/log/nginx/ /var/run/
ADD nginx.conf /etc/nginx/nginx.conf
```
{{< /details >}}

Create the container image with `docker build -t pip_proxy .`. Then create a volume for storing the cached packages `docker volumes create pip-cache-data`. 
Then start a container:

```sh
docker run -d -p 80:80 -v pip-cache-data:/var/lib/nginx/pypi/ pip_proxy
```

If you prefer to deploy this on a Kubernetes cluster :
```
k create deployment pip-proxy --image <image_tag> --port 80
k expose deployment pip-proxy --port 80 --target-port 80
k create ingress pip-proxy --rule="pip.local.domain.fr/*=pip-proxy:80"
```

### telling pip to use our proxy

From `pip3 install --help`:
```
Package Index Options:
  -i, --index-url <url>       Base URL of the Python Package Index (default https://pypi.org/simple). 
                              This should point to a repository compliant with PEP 503 (the simple repository API) 
                              or a local directory laid out in the same format.
  --trusted-host <hostname>   Mark this host or host:port pair as trusted, even though it
                              does not have valid or any HTTPS.
```

This means we can redirect to another package index, using either the `-i` argument, or through the __PIP_INDEX_URL__ env var.
In case the proxy is using self-signed or non-valid certificates, you can use `--trusted-host` or the __PIP_TRUSTED_HOST__ env var.

### changes to the CI


In our Gitlab group, under Settings > CI/CD > Variables, we can configure these env vars across all our pipelines:

![gitlab env var management](/pip-proxy/env-var-gitlab.png)

Here is an excerpt of a CI stage installing torch:

Before, using directly the PYPI repo:

```
> time pip install --no-cache torch
Collecting torch
  Downloading torch-2.0.1-cp310-cp310-manylinux1_x86_64.whl (619.9 MB)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 619.9/619.9 MB 11.4 MB/s eta 0:00:00
...
real	5m26.790s
user	1m39.378s
sys	0m38.067s
```

After, using the proxy:
```
PIP_INDEX_URL=https://pip.local.domain.fr/simple
PIP_TRUSTED_HOST=pip.local.domain.fr
> pip install --no-cache torch
Looking in indexes: https://pip.local.domain.fr/simple
Collecting torch
  Downloading http://pip.local.domain.fr/packages/8c/4d/17e07377c9c3d1a0c4eb3fde1c7c16b5a0ce6133ddbabc08ceef6b7f2645/torch-2.0.1-cp310-cp310-manylinux1_x86_64.whl (619.9 MB)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 619.9/619.9 MB 89.7 MB/s eta 0:00:00
...
real	2m11.356s
user	1m20.170s
sys	0m32.175s
```
We can see that on the second run, pip downloaded `torch` from our proxy, leading to an ~8x faster download speed. Some packages weren't cached, but next time they are being downloaded, our proxy will serve them from its cache, saving even more time.

For that particular example, we've shaved off more than 3 minutes, or an improvement of ~2.5x time wise !
This is a _best-case_ scenario, with heavy packages, but we've seen gains across the board.

I haven't been able to measure how many MB (or maybe GB) of packages we haven't downloaded from PYPI, and therefore how much bandwith we saved, but after only 2 weeks of using the cache, it is now weighting in at around 3.2GB. Speculating that we've downloaded the same version of most of these packages at least a few more times, it's safe to say that we saved tens of GB !

```
root@pip-proxy-54789c97df-jsg95:/# du -sh /var/lib/nginx/pypi/
3.2G	/var/lib/nginx/pypi/
```

Overall, the solution was deployed in less than a few hours. It's now '_battletested_' across hundreds of pipelines, has saved us hours of CI time and avoided re-re-re-downloading tens of gigabytes worth of packages from PYPI. Hopefully we'll never have any issues with it ! 

_(new post on our CI being broken incoming..)_