---
title: "A Monkey in the Cluster"
date: 2021-08-11T08:49:41+02:00
description: "apply the Chaos Engineering principles to k8s"
tags: []
---

## what & why 

From [principlesofchaos.org](https://principlesofchaos.org) :

*Advances in large-scale, distributed software systems are changing the game for software engineering. As an industry, we are quick to adopt practices that increase flexibility of development and velocity of deployment. An urgent question follows on the heels of these benefits: How much confidence we can have in the complex systems that we put into production?*

Applying this philosophy to kube is a very pertinent thing to do, but how ? The same website defines Chaos Engineering as *the discipline of experimenting on a system in order to build confidence in the system’s capability to withstand turbulent conditions in production.* 

So, let's introduce _turbulences_ in our cluster. 

Netflix developed their [Chaos Monkey](https://netflix.github.io/chaosmonkey/) a while back, and this is basically the same thing, applied to kubernetes concepts.

A monkey, in the cluster, breaking things. The easiest route for this is attacking the primary Kube resource, pods. Let's terminate some random pods and see what happens.

We are sure that kubernetes __will__ restart our pods if we have defined any kind of top level management over them (such as deployments, daemonsets, etc..). Killing a pod is about testing whether our application can withstand it. 

## how

This is also my first *real* golang project, using some of the language's specific features about concurrency (go routines, channels) and structs.

The project is made of 3 go routines, each communicating with the other using channels. The configuration is handled through a struct.

- The main routine is a simple _sleeps until the next cron occurence, notify the killer routine, repeat_ loop.
- The killer routine waits for a message from the main routine, then list pods that match the criterias, select one of them and terminate it, and sends a message to the slack routine about what happened.
- the slack routine, which waits for a message and simply transmits the message to the channel (if any).

This might not be the simplest approach, as a simple sleep->kill->message->loop would have sufficed, but this is also about learning the ins-and-outs of the language.

the project is hosted [here](https://github.com/k0rventen/macaque), and can be deployed on any cluster in 3 commands:

```
# download the spec file
curl -LO https://raw.githubusercontent.com/k0rventen/macaque/main/macaque.yml

# edit the env vars to match your config
$EDITOR macaque.yml

# apply (make sure you are in the right ns)
kubectl apply -f macaque.yml
```

The containers are available for both `amd64` and `arm64`. The RBAC configuration is included in the spec file, the pod needs _list_ and _delete_ of the __pods__ resource in the current namespace.

The configuration is done through env var. You _must_ specify the crontab spec and the namespace in which to kill pods, and you _can_ add a label selector to narrow the targets, add a slack token and channel ID to be informed when the monkey does things.


