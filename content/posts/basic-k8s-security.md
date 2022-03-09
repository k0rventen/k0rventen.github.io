---
title: "A basic, security-minded k8s app setup"
date: 2022-03-09
draft: true
description: "Add a layer of security to your deployment without too much hassle"
tags : ["k8s","security","CKS"]
---


## what & why 


The CKS (Certified Kubernetes Security Specialist) is a great resource for knowing how to secure a kubernetes cluster.
It covers a lot of topics, from the cluster side (admission controller, webhooks, audit), app side (Pod Security Policies) and supply chain (image scanning). Another great resource for this is the [Kubernetes Hardening Guidance by NSA & CISA](https://media.defense.gov/2021/Aug/03/2002820425/-1/-1/1/CTR_KUBERNETESHARDENINGGUIDANCE.PDF)

But some of the concepts defined in both these resources are very case-specific, and require a lot of time, tools & effort to setup. In some environnements, it might be infeasible to deploy each and every one of those concepts. But that doesn't mean we should avoid some basic security-minded steps when deploying to k8s. I won't cover things on the cluster-side (audit, tools like falco, or admission controllers), but how you can improve the security of your front-facing app by adding a few lines here and there.

## how

Let say we have a python app, that exposes an API. We have a basic Dockerfile for it, and a simple `deploy.yaml` spec file containing our Deployment. They are what you could call 'typical' of what can be found online when looking for a template of dockerfile or deployment:

Dockerfile:
```dockerfile
FROM python:3-alpine
COPY requirements.txt .
RUN pip3 install -r requirements.txt

WORKDIR /app
COPY src/ ./

ENV PYTHONUNBUFFERED 1
CMD ["python3","app.py"]
```

deployment manifest:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: registry/api:latest
        ports:
        - containerPort: 5000
```

Let's secure things up :


### non root user
The first recommendation is to run our containers as non-root users. For that, we'll first add a few lines to our Dockerfile:

```dockerfile
...
RUN addgroup -S app && adduser -H -D -S app -G app -s /dev/null
USER app:app
WORKDIR /app
```
__Note that we are using an alpine-based container, so the exact command might vary on other distros, but the goal is the same__

By creating a user 'app', and using it to run our app, we avoid giving _way too much_ permissions to the app.
We can check that by exec'ing into the running container:

(before)
```sh
/app # id
uid=0(root) gid=0(root) groups=1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
/app # ps
PID   USER     TIME  COMMAND
    1 root      0:00 {flask-api.py} /usr/local/bin/python3 ./flask-api.py
    7 root      0:00 sh
   14 root      0:00 ps
```

(now)
```sh
/app $ id
uid=101(app) gid=101(app)
/app $ ps
PID   USER     TIME  COMMAND
    1 app       0:00 {flask-api.py} /usr/local/bin/python3 ./flask-api.py
    7 app       0:00 sh
   14 app       0:00 ps
```

Right, so now we are not running as root on the container side, but what about the host ? To which user are we mapped to on the host side ? 

when running the default image:
```
k8s-worker > ps -aux | grep flask
root     2266529  1.8  0.1  28168 23752 ?        Ss   17:31   0:00 /usr/local/bin/python3 ./flask-api.py
```

We are actually mapped to the root user ! that's not the most secure setup ! If somehow an attacker gain control of the pod and is able to escape, he will land on the host as the root user.



And if we use the new Dockerfile with the USER directive:
```
ps -aux | grep flask
syslog   2267104  2.8  0.1  28168 23812 ?        Ss   17:32   0:00 /usr/local/bin/python3 ./flask-api.py
```

What ? Why are we mapped to the syslog user ? A quick check of `/etc/passwd` shows us why :

```
cat /etc/passwd | grep 101
syslog:x:101:107::/home/syslog:/usr/sbin/nologin
```

This is because when we created the user `app` in the Dockerfile, it assigned to it the uid 101, which is the same as the syslog user on our host. 

To avoid clashing with a potential user with the same uid on the host, we can use a higher uid, in the `40000-60000` range.

### runAsUser

To fix that, we will tweak our `deploy.yaml`:
```yaml
...
      containers:
      - name: api
        image: registry/api:latest
        securityContext:
          runAsUser: 60096
          runAsGroup: 60096
...
```

Now, from the host side, we will appear as uid `60096`, which isn't mapped to a predefined user (unless a user with the same uid exists on the host obviously). 


### readOnlyRootFilesystem
Another great addition to the Deployment spec, it to set the filesystem as readonly. 
This will block any attempt to modify the filesystem of the container, like installing binaries, modifying configuration in /etc..


```yaml
      containers:
      - name: api
        image: registry/api:latest
        securityContext:
          readOnlyRootFilesystem: true
          runAsUser: 60096
          runAsGroup: 60096
```



### automountServiceAccountToken
If the pod is not going to communicate with the kubernetes API, we can avoid mounting the service account's token in the pod (which by default will be mounted in `/var/run/secrets/kubernetes.io/serviceaccount/token`):

```yaml
...
    spec:
      automountServiceAccountToken: false
      containers:
...
```


### resources

While we're on the deployment, it's also a good idea to set some resources limits on the pod. This will prevent the pods from consuming all the resources from the host, which even if it's from a genuine mistake, can result in outages or other disurptions:

```yaml
...
      containers:
      - name: api
        image: registry/api:latest
        resources:
          limits:
            cpu: 500m
            memory: 128Mi
          requests:
            cpu: 100m
            memory: 64Mi
...
```

`requests` will tell k8s the requirements for the pod, i.e what we can expect the pod to consume. This will aid the scheduling on an appropriate node.

`limits` will actually stop the pod from consuming more than what is specified, either by throttling for the cpu, or OOM for the memory.


### SHA tagging

Another recommendation would be to use SHA tagging on the base image of our Dockerfile. This serves two purposes:

- making reproducible builds possible. Otherwise, as the base image can be updated, this will break our current setup even though our Dockerfile hasn't changed.
- aleviate supply chain attacks: If the base image used is subject to a supply chain attack (a threat actor injects/modify the image), our image becomes subject as well because we'll pull the latest version of the image.

To do so, we simply add the SHA of the image we want to fix at the end of the tag:

```dockerfile
FROM python:3.9-alpine3.15@sha256:f2aeefbeb3846b146a8ad9b995af469d249272af804b309318e2c72c9ca035b0
```

### Results
Final versions of the Dockerfile and deploy.yaml would look like this:

```dockerfile
FROM python:3.9-alpine3.15@sha256:f2aeefbeb3846b146a8ad9b995af469d249272af804b309318e2c72c9ca035b0
COPY requirements.txt .
RUN pip3 install -r requirements.txt

RUN addgroup -S app && adduser -H -D -S app -G app -s /dev/null
USER app:app
WORKDIR /app
COPY src/ ./

ENV PYTHONUNBUFFERED 1
CMD ["python3","app.py"]
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      automountServiceAccountToken: false
      containers:
      - name: api
        image: registry/api:latest
        securityContext:
          readOnlyRootFilesystem: true
          runAsUser: 69096
          runAsGroup: 69096
        ports:
        - containerPort: 5000
```
