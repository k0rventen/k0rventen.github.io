---
title: "Contributing to the k8s documentation"
date: 2023-01-31
description: "translating tasks in french"
tags : ["k8s","oss","contribution"]
---

# what & why

In late 2022 while preparing a workshop around k8s for some french people,
I realized that a lot of the [k8s documentation](https://kubernetes.io/docs/home/) isn't translated in french.

## What to translate and what not to
Albeit I'm not a fan of trying to translate the concepts name, ressources or objects revolving around k8s
(for example `PersistentVolumeClaim` should not be translated as it's used in config files, command lines args etc),
it can be beneficial to translate the documentation itself for non-english native to better grasp a given concept.

I then decided to step up my OSS contribution for 2023, by translating and improving the overall k8s documentation, focusing
mainly on the tasks, which I think are crucial when learning a new concept.

Another goal of this project is to improve my comprehension of various k8s concepts, level-up my translation skills,
and help out on a project that I've been using daily for the past 3 years.

# how

## Current goal & progress

My curent progress can be tracked [through Gihub PRs](https://github.com/kubernetes/website/pulls?q=is%3Apr+author%3Ak0rventen+)

Although I do not have a specific number of contributions in mind, 
I hope to translate around 2 or 3 tasks per month. 
We'll see if that goal will age like milk or fine wine ;)

## Start contributing

Contributing to the k8s documentation is fairly easy, and well documented:

Once you've forked the [repo](https://github.com/kubernetes/website), 
create a new branch whose name will be defined by the type of 
contribution you'll want to make (see the PR help for guidance.)

The project is using [hugo](https://gohugo.io/) as its building tool. 
You can either use it directly, or through a container to visualize your changes locally.
In the repo dir, run 

```
# once to pull the submodules
make module-init

# then to build and serve the website
make serve
```

You can then access your changes on `localhost:1313`.


Finally, commit your changes to your branch with an explicit message. 
Once you've good to go, open a PR. The first time, you'll need to sign the CNCF CLA.
