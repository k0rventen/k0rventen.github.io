---
title: "Remote layer cache for multiple docker CI runners"
date: 2024-02-19
description: "Improve your CI build times using a common layer caching registry"
tags: ["docker","linux","CI", "cloud-init","buildx"]
---

# what and why

At $job, we are using jenkins with a dozen or so docker runners, each running their own docker daemon. At least a few hundred builds are carried out daily on these runners, mainly producing docker images that are then pushed onto a testing/production container registry.

But two jobs from the same repo might not be using the same CI runner (most of the time they are not). It means each docker runner might need to rebuild the first couple of layers from a given Dockerfile, despite another worker having already built the same layers a few hours/minutes ago. That's wasting CPU cycles, bandwith, and it's also increasing the time each build is taking.

So the goal is to find a way for each worker to share its layers to the others, and for everyone to be able to use this system to pull redundant layers that might already exist.


# how

The setup is very simple: We'll use a dedicated docker registry (using the `registry` image), as a centralised layer cache. Then we'll configure each worker to point to that registry when building an image.

Now, when a runner builds an image, it will store the intermediary layers in this shared registry, for other runners to use.
And when another runner need to build an image with the same starting layers, he'll simply pull from this registry, rather than rebuilding locally the same layers.

Here is an overview of a PoC setup we'll deploy to test our hypothesis:
- vm1, our docker registry
- vm2 and vm3, two 'CI runners' (for our purpose, they will only have docker installed and we'll manually launch 'jobs')

To reproduce, you can use anything that can create VMs/containers, like multipass, compose, kvm, virtualbox, distrobox, or even 3 real machines. 

## setup (using multipass)
I will be using multipass, but anything that can create a network with multiple VM should do.

We'll leverage `cloud-init` to provision our VM, if your provider supports it, you can copy the content of the following files:

__registry.yaml__
```yaml
runcmd:
  - "curl -fsSL https://get.docker.com -o get-docker.sh"
  - "sh get-docker.sh"
  - "docker run -d -p 5000:5000 --name registry registry:latest"
```

__worker.yaml__
```yaml
runcmd:
  - "curl -fsSL https://get.docker.com -o get-docker.sh"
  - "sh get-docker.sh"
  - "usermod -aG docker ubuntu"

write_files:
- owner: ubuntu:ubuntu
  path: /home/ubuntu/buildkit.toml
  permissions: '0644'
  content: |
    [registry."registry:5000"]
      http = true
```

Now, create 3 VMs using these files:

```shell
multipass launch -n registry --cloud-init registry.yaml 22.04
multipass launch -n worker1 --cloud-init worker.yaml 22.04
multipass launch -n worker2 --cloud-init worker.yaml 22.04
```

We can verify that the registry is actually running the container registry:
```shell
> multipass exec registry sudo docker ps
CONTAINER ID   IMAGE             COMMAND                  CREATED         STATUS         PORTS                                       NAMES
e3e83c6d6c69   registry:latest   "/entrypoint.sh /etc…"   2 minutes ago   Up 2 minutes   0.0.0.0:5000->5000/tcp, :::5000->5000/tcp   registry
```

## manual setup

If deploying manually, once you have the 3 machines setup: 
- install docker on all of them:
- start a container registry on our registry machine:
  ```
  docker run -d -p 5000:5000 --name registry registry:latest
  ```
- configure dns so that the workers can access the registry at _registry_ (this is because the buildx backend for docker does not use /etc/hosts), so you might need an external DNS where you can add A records for the registry machine.


That's it, we now have a container registry available at `registry:5000`. 
It's not production ready, as it's serving over HTTP and has no auth, but for our use-case this will suffice.

## building our first image

Now let's create a Dockerfile that we'll execute on one of our worker:

(`multipass shell worker1`)

```dockerfile
FROM alpine
RUN apk add jq
RUN sleep 20 # let's say we build some boilerplate stuff here
RUN echo "$(date)" > /date
```

If we instruct docker to build it:

```shell
worker1:~$ time docker build -t app .
[...]
 => => naming to docker.io/library/app

real    0m23.446s
user    0m0.133s
sys     0m0.021s
```

ok, so 23s to build it. 
Now let's say our second worker has to build the same image (do not forget to copy the Dockerfile on worker2).
Running that on our _worker2_ should take around the same time:
(`multipass shell worker2`):
```shell
worker2:~$ time docker build -t app .
[...]
 => => naming to docker.io/library/app

real    0m23.449s
user    0m0.126s
sys     0m0.047s
```

But if we run it again on worker1:
```shell
worker1:~$ time docker build -t app .
[...]
 => CACHED [2/4] RUN apk add jq
 => CACHED [3/4] RUN sleep 20 # let's say we build some boilerplate stuff here
 => CACHED [4/4] RUN echo "$(date)" > /date
 => exporting to image
 => => exporting layers
 => => writing image sha256:d902f59380db83b19d90aff37674566688db1895f97c418f7f0a561a368b54d3
 => => naming to docker.io/library/app

real    0m0.889s
user    0m0.075s
sys     0m0.024s
```

Note the __CACHED__ in some of the log lines on our worker1. That's because the layers for the first 3 instructions of the Dockerfile are already present in our first worker. He's using them rather than building them as he did the first time around. 

## configuring the cache registry
So now, let's make use of our registry and share these layers between runners. So when we update the Dockerfile, runners who haven't yet built this image can take advantage of the registry.

For that, we'll use the following arguments to our docker command:

- `buildx`: only the buildx backend supports the use of external caching mecanisms as the one we are using
  here is the [buildx documentation](https://docs.docker.com/reference/cli/docker/buildx/build/)
- `--cache-from type=registry,ref=registry.local/image`: tell docker to cache the layer we build to this registry
- `--cache-to type=registry,ref=registry.local/image`: tell docker to check this registry before building a layler
- `--push` or `--load`: either push the final image to the registry, or load it to the host's docker engine.


### buildkit config
Due to our unsecure setup, we'll have to tell buildx that our registry is using http. On both workers, create a file `buildkit.toml`:
```toml
[registry."registry.local"]
  http = true
```

Then create our builkit  with our config:
```shell
> docker buildx create --config=buildkit.toml  --use
quirky_panini # that's cute
```

### let's finally use the registry

We'll change the base image of our Dockerfile, so we know that the first time we build it, we can't use any of the cache we have already. 
Let's change the base image from alpine to python:
```Dockerfile
FROM python:alpine
```
Now let's try to build our image with our shared registry:

On worker1:
```shell
> docker buildx build -t registry:5000/image \
  --cache-from type=registry,ref=registry:5000/image \
  --cache-to type=registry,ref=registry:5000/image --load .

[+] Building 29.9s (11/11) FINISHED
 => [internal] booting buildkit
 => => pulling image moby/buildkit:buildx-stable-1
 => => creating container buildx_buildkit_amazing_babbage0
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 154B
 => [internal] load metadata for docker.io/library/alpine:latest
 => [internal] load .dockerignore
 => => transferring context: 2B
 => ERROR importing cache manifest from registry:5000/image
 => [1/4] FROM docker.io/library/python:alpine@sha256:1a0501213b470de000d8432b3caab9d8de5489e9443c2cc7ccaa
 => => resolve docker.io/library/python:alpine@sha256:1a0501213b470de000d8432b3caab9d8de5489e9443c2cc7ccaa
 => => sha256:4abcf20661432fb2d719aaf90656f55c287f8ca915dc1c92ec14ff61e67fbaf8 3.41MB / 3.41MB
 => => extracting sha256:4abcf20661432fb2d719aaf90656f55c287f8ca915dc1c92ec14ff61e67fbaf8
 => [2/4] RUN apk add jq
 => [3/4] RUN sleep 20 # let's say we build some boilerplate stuff here
 => [4/4] RUN echo "$(date)" > /date
 => exporting to image
 => => exporting layers
 => => exporting manifest sha256:c13b6d9ce9d3d64e17f3443ae9082cf1b9c6e9e07922188900bc9942175fb073
 => => exporting config sha256:0da8809d7104cf20453a6b2d2276b089f40bfb555e0254db6fa40b0f39aa07ae
 => => exporting attestation manifest sha256:113dfd6d03ed8c503d0b91ef9c69ec6f9c0fb92b9d656062ec3e79ceb9d0a
 => => exporting manifest list sha256:35ba11d8517d1452341090bf6884afd35b595389cf6559988662d76f7e62851d
 => => pushing layers
 => => pushing manifest for registry:5000/image:latest@sha256:35ba11d8517d1452341090bf6884afd35b595389cf65
 => exporting cache to registry
 => => preparing build cache for export
 => => writing layer sha256:4abcf20661432fb2d719aaf90656f55c287f8ca915dc1c92ec14ff61e67fbaf8
 => => writing layer sha256:4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1
 => => writing layer sha256:97a760744e8ba94a04280f62d469902bcb58b128da9f6501db9822ee8ded0a63
 => => writing layer sha256:cc84016181cd34ccdc572a0a034e46fe491d3a01967328d7370bab371a17c868
 => => writing config sha256:60802e2ae4cac776269d496cd99bf016a2fd51220214c8736e63914a0eca9ca8
 => => writing cache manifest sha256:610b85677a133f2ea67eecbbc3ba704e0d3eddf65b48ec0c4293b89d28a3a42b
------
 > importing cache manifest from registry:5000/image:

real    0m25.925s
user    0m0.345s
sys     0m0.136s
```
Again, around 25s (there are a few seconds for the buildkit container to boot up).
But now, let's do the same thing on the second worker. We'll prune it beforehand, so it has no local cache for what we'll be building:

```shell
> docker system prune -a -f
[...]
Total reclaimed space: 46.23MB

> docker buildx create --config=buildkit.toml  --use
vibrant_cohen

> time docker buildx build -t registry:5000/image \
  --cache-from type=registry,ref=registry:5000/image \
  --cache-to type=registry,ref=registry:5000/image --load .

[+] Building 2.4s (11/11) FINISHED                                             docker-container:pensive_taussig
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 161B
 => [internal] load metadata for docker.io/library/python:alpine
 => [internal] load .dockerignore
 => => transferring context: 2B
 => importing cache manifest from registry:5000/image
 => => inferred cache manifest type: application/vnd.oci.image.index.v1+json
 => [1/4] FROM docker.io/library/python:alpine@sha256:1a0501213b470de000d8432b3caab9d8de5489e9443c2cc7cca
 => => resolve docker.io/library/python:alpine@sha256:1a0501213b470de000d8432b3caab9d8de5489e9443c2cc7cca
 => CACHED [2/4] RUN apk add jq
 => CACHED [3/4] RUN sleep 20 # let's say we build some boilerplate stuff here
 => CACHED [4/4] RUN echo "$(date)" > /date2
 => exporting to docker image format
 => => exporting layers
 => => exporting manifest sha256:4532df521ca93c2519f9ff8338f30e13fba723332447bcd3e003dd47630142a2
 => => exporting config sha256:9debadcc86872631a1a0b7eafd2972d6beca3456f0b043eb80b52d2681a0d548
 => => sending tarball
 => importing to docker
 => => loading layer d4fc045c9e3a 65.54kB / 3.41MB
 => => loading layer 678cac8b069e 32.77kB / 622.15kB
 => => loading layer 0c9bfb14c909 131.07kB / 11.77MB
 => => loading layer d2968c01735e 242B / 242B
 => => loading layer 5305019f4685 32.77kB / 2.70MB
 => => loading layer 37d2dfc1707b 32.77kB / 2.71MB
 => => loading layer 5f70bf18a086 32B / 32B
 => => loading layer 5a36026cdcc3 126B / 126B
 => exporting cache to registry
 => => preparing build cache for export
 => => writing layer sha256:270999341ddcf70feedda4bff6d081483f1ad384e5aa13f268f828ed469f5402
 => => writing layer sha256:4abcf20661432fb2d719aaf90656f55c287f8ca915dc1c92ec14ff61e67fbaf8
 => => writing layer sha256:4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1
 => => writing layer sha256:4fc96b5c1ba465ba27fb55d4766ade8624de4082ac1530b3293ac735ab3ead50
 => => writing layer sha256:a8fd6f3f484fdfccf33965ca0f8807e5078a619803cf638d82bc4a405e91de04
 => => writing layer sha256:caa4e319395ae52ea041b5a6cca32833cecc2b192a18cef42e77a6e0446c9f4a
 => => writing layer sha256:dca80dc46cecdd1a97787a1dd6f74263b9d2f7b0dd3e2e15c109f5e34848c932
 => => writing layer sha256:fe9e15b6315c34de5c802bdbd343e3ec69bdc4ab870783fc1b9552daaef25e77
 => => writing config sha256:fccd66ca6f5e29c42a8444b3f74df1ecb8c94114429a851e093de718ba55decc
 => => writing cache manifest sha256:b76d6f554cffd020b6b14656e332527dfb19ab01376d0473cc12a5580a2d9c45

real    0m2.625s
user    0m0.255s
sys     0m0.041s
```
That was super fast, because for most of the layers, there was a cache hit in the registry. That means whatever layer has been built by another worker, our worker2 can now access it and use it without building it ! 

Now if we tweak the Dockerfile a bit, and rerun the command, we might have some cache misses on the new layers, but it's still an improvement !

Whenever a runner will need these first few layers 
(eg building dependencies, compiling some boilerplate stuff, etc).. he will be able to pull them from this cache, 
and only work on what matters (compiling code that has changed, copying over build artifacts..).

## quick maths

In this _real world very production grade_ example, we've reduced the build time from ~20s to ~2s. No matter what the rest of the Dockerfile looks like, it's 18 seconds shaved off the total runtime for this particular job. Let's say these boilerplate layers are used in a repository with 20 commits a day, 5 days a week, we could shave off 
__(18s per run) * (20 runs per day) * 5 days = 30 minutes__
of CI runtime weekly. Multiply that by the number of repos * weeks worked in a year, and this number can quickly tally up into __days__ ! 


## limitations and caveats

This setup isn't perfect, and there are a few drawbacks/things to consider when thinking about deploying such a system:

First, it's needless to say, the simple __registry:latest__ container depicted in this setup isn't prepared for much more, as there is no persistent storage, and plain HTTP is used. A more robust container registry might be needed (think Harbor)

Second, because this is using _buildx_, you have to choose between loading the resulting image (eg for testing), or pushing it to the registry, as using both `--pull` and `--load` isn't allowed. That might be fine for a (git pull/ docker build/docker push) type of CI, but if you need to both push and use the image, you're out of luck, and you'll surely need to run two commands. 
Third, and maybe the the main caveat about this setup: `cache invalidation`:
- one of your worker pulls an image, URL or ressource, creates a layer out of it and pushes it to the cache
- you obviously want to use this layer as much as possible, reducing bandwidth usage, compute time, etc
- the external ressource gets updated (eg a new commit, updated base image..)
- But your local instruction for fetching the resource hasn't changed (it's still `RUN git clone`)
- you are now out of sync with the resource, building outdated layers.

And there lies the root issue, of __when__ should we invalidate a given layer on the registry.
Doing it too often kinda defeats the purpose of the shared registry,
on the other hand doing it at sparse intervals mean higher chance of using outdated layers.

There is no silver bullet for this particular problem, it depends solely on the setup/goal.

Finally, depending on how many workers/repos/build are used,
this can create a huge number of layers in the registry. And all this cache can accumulate quickly, using quite a lot of disk space over time.

Happy caching !