---
title: "Reducing Docker Images Size Using Xz"
date: 2021-09-24T20:14:09+02:00
description: "Compression-ception"
tags: []
---

## what & why 

During a project, I needed to build a container that could render graphs based on pretty big arrays, using `plotly`, `kaleido` and `pandas`. 

The arrays would be DataFrames from pandas, turned into graphs through plotly, and then renderer as jpeg images using kaleido. 

This is not uncommon to have pretty big dependencies in a python project, but when pulling these pacakges locally, it took quite a long time, so I checked the size of each : 

```
root@69ee6367d91f:/usr/local/lib/python3.9/site-packages# du -sh .
536M    .

root@69ee6367d91f:/usr/local/lib/python3.9/site-packages# du -sh * | sort -h | tail -n 5
30M     numpy
33M     numpy.libs
58M     pandas
140M    plotly
221M    kaleido
```

Well, a `536M` dependencies folder. Turns out that [kaleido](https://pypi.org/project/kaleido/) `embeds the open-source Chromium browser as a library`, and plotly and pandas are both pretty big dependencies by themselves. 

That won't make for a nice and small container. Let's see how we can improve things !

## how

First, let's try to create a basic, simple docker image with these dependencies.

requirements.txt
```
pandas==1.3.1
kaleido==0.2.1
plotly==5.2.1
flask==2.0.1
```

### basic dockerfile
A very simple dockerfile for this might look like this : 
```dockerfile
FROM python:3.9
WORKDIR /build
COPY requirements.txt .
RUN pip3 install -r requirements.txt
COPY app.py .

# launch
CMD ["python3","-u","app.py"]
```

That's fine, but the resulting image is quite heavy : 

```
> docker images | grep renderer
renderer                  full              35b81d0fd3f7   10 minutes ago   1.5GB
```

Oh well. A `1.5GB` container. That's Windows territory ! Surely we can go under a GB.


### multi layer

We can use the multi-layer system of docker to build a smaller image. 

Here we have two improvements : 
- we are using a `slim` image as our final layer, which is lighter than the full `python:3.9`. Note that due to our dependencies, we can't use an _alpine_ based image, otherwise we would have been much lower regarding the size.
- we only copy what we need from the build layer.


The dockerfile might look like this : 

```dockerfile
# build layer
FROM python:3.9 as builder
WORKDIR /build
COPY requirements.txt .
RUN pip3 install --prefix /install -r requirements.txt

# final layer
FROM python:3.9-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .

# launch
CMD ["python3","-u","app.py"]
```

Once we've built the dependencies in the build layer, we copy the _site-packages_ folder to the final layer.

```
> docker images | grep renderer
renderer                  slim              5401960f2a66   10 seconds ago   577MB
renderer                  full              35b81d0fd3f7   16 minutes ago   1.5GB
```

That's better. _Only_ 577MB, this is just shy of 1/3 the original size.

### here comes the compression

This is where something occured to me.

Why not compress the whole dependency folder when building, and decompress it on-the-go when starting the container ? 


Here is the Dockerfile:

```dockerfile
# build layer
FROM python:3.9 as builder
RUN apt update && apt install xz-utils -y
WORKDIR /build
COPY requirements.txt .
RUN pip3 install -r requirements.txt
RUN XZ_OPT="-T 0" tar Jcf packages.tar.xz /usr/local/lib/python3.9/site-packages/

# final layer
FROM python:3.9-slim
RUN apt update && apt install xz-utils --no-install-recommends -y && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /build/packages.tar.xz .
COPY app.py .

# launch
CMD ["python3","-u","app.py"]
```

In our app.py, before importing the libraries:

```py
# before loading modules, decompress the site-package archive
import subprocess
decompress = subprocess.run(["tar","Jxf", "packages.tar.xz" ,"-C", "/"],env={"XZ_OPT":"-T 0"},capture_output=True)

import ...
```

Looking at the produced container image : 

```
> docker images | grep renderer
renderer                  xz                d1def5592c6e   18 seconds ago   208MB         
renderer                  slim              5401960f2a66   4 minutes ago    577MB
renderer                  full              35b81d0fd3f7   16 minutes ago   1.5GB
```

`208MB`! That's not bad. 

Docker compresses the image when uploaded to the registry, so let's push our images and see what the size differences are there:

![](/docker-xz/registry.png)

The gains are impressive when using a slim/multi-layer dockerfile. And by compressing our libs we gained 50MB, a ~30% improvement.

## conclusions

This is fun, but not an ideal solution for handling "big" containers:

- Size-wise, the final container is still 208MB, which is a `63%` decrease in size!
- but once uploaded to a registry, and the image being compressed as a whole there, the size decrease by _only_ `29%`.

- When starting the container, you'll need to decompress the packages, which (on my machine) took a few seconds. This should also be taken into account.

If network bandwidth was a constraint, this solution will not help much. You'll pull 50MB less, but that's not _groundbreaking_.

The only use case I can see is if you have storage limitations on the receiving end, as the savings are much more important once the whole image is decompressed by docker. But you will still need to decompress the package when launching a container with this image, so the gains are limited to the image.

Despite this whole setup being not-as-practical as I thought it would initially (before reminding myself of the whole docker registry compression..), this could still be _somewhat (maybe)_ useful in the future, so i'll still post it..