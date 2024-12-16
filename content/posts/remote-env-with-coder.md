---
title: "Remote development in Kubernetes With Coder"
date: 2023-06-22
description: "It's time to live in Kubernetes."
tags: ["remote","k8s","coder"]
---

_A fleet of remote development environments (with docker, fish shell, and even minikube) running in your kubernetes cluster, accessible through VS Code in the browser !_

{{< video src="/coder-remote-env/demo.mp4" type="video/mp4" >}}


# What & why

This setup is the v2 of a previous post on remote dev env [using jupyterlab](/posts/remote-mulituser-vscode-kubernetes/) I made a year and a half ago. Thee OG setup was functionnal, but it had some issues, mainly around user management, container lifecycle and persistent data handling. As $dayjob has grown, so has the infrastructure, and so has the development needs. So a new solution was required.

A lot of them exists right now for remote environments, from providers like [Github Codespaces](https://github.com/features/codespaces), [Gitpod](https://www.gitpod.io/), or even [DevPod](https://devpod.sh/). But the folks at Coder released [coder v2](https://github.com/coder/coder) a while back, and that's what I've used for managing our team's environments since late 2022.

The devs needs haven't changed a lot since the first post. Our workflow is cluster-centric, based on skaffold to redeploy our built-on-the-fly-containers as pods directly onto the cluster. 

# How

The stack consists of these parts:
- a docker image that will be used as the base for our remote envs
- a kubernetes cluster, which will host everything,
- the coder platform deployed on said cluster,
- a custom kubernetes provider for running our docker image inside coder, handling some specific needs we have with our dev envs



## The Base Image

The idea of the base image is to bake everything needed directly into it: vscode, git, fish shell, docker (running in a Docker-in-Docker fashion). I've already built this image, available at [_k0rventen/code_](https://hub.docker.com/r/k0rventen/code/tags), but if you want to tweak it, you'll find the necessary files below:

We're using an Ubuntu base, plus:
- we install basic dev utils and requirements for running dockerd 
- we copy the dockerd stuff from their own image
- we install code-server
- we change the default shell to fish and copy over our base config files
- we start a _bootstrap.fish_ script

```Dockerfile
# base image using ubuntu
FROM ubuntu:23.04

# install utils (fish shell, ssh)
RUN apt update && apt install -y --no-install-recommends curl ca-certificates git iptables fuse-overlayfs dnsutils less fish openssh-client && apt clean

#install code-server
RUN curl -fsSL https://code-server.dev/install.sh | sh -s -- --version 4.14.0 && rm -rvf /root/.cache

# copy dockerd binaries from the docker image
COPY --from=docker:20-dind /usr/local/bin/ /usr/local/bin/

# shell config
RUN chsh -s /usr/bin/fish
COPY config/ /tmp/code

# run our launch script
ENTRYPOINT ["fish", "/tmp/code/bootstrap.fish"]
```

The `bootstrap.fish` has the following duties:
- make sure mandatory directories are here
- install Linuxbrew if not present (which will run only once, during the first startup of the env)
- start the dockerd daemon in the background
- then start code-server

Here is its content: 
_bootstrap.fish_
```shell
cd $home

mkdir -p projects .config/fish

if test ! -e .config/fish/config.fish
  echo "copying fish config"
  cp -v /tmp/code/config.fish  .config/fish/config.fish
end


if test ! -e /home/linuxbrew/.linuxbrew/bin
  echo "installing linuxbrew"
  bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' &
end

echo "starting dockerd.."
sh /usr/local/bin/dockerd-entrypoint.sh &

echo "starting code server"
exec code-server --bind-addr 0.0.0.0:9069 --auth none --disable-telemetry --disable-update-check projects
```

The _config.fish_ is a very minimal config to get us started:

_config.fish_
```shell
# quiet fish
set fish_greeting
set -gx HOMEBREW_NO_ENV_HINTS 1
set -gx HOMEBREW_NO_INSTALL_CLEANUP 1

# brew fish
fish_add_path /home/linuxbrew/.linuxbrew/bin

# simple fish 
function fish_prompt
  printf '\n%s[%s]%s > ' (set_color cyan) (prompt_pwd) (set_color normal)
end
```


## The Coder platform

Coder can be installed on a lot of platform, including docker, k8s and friends. Here we'll concentrate on Kube. Requirements are a cluster with a storage class and an Ingress controller. You'll need `helm` as well.

From this point forward, I'll assume that you have a cluster which can be accessed using the domain names `coder.org` and `*.coder.org` (You can add them in your local DNS server, or as entries in your /etc/hosts file _wildcards aren't supported, but for testing purposes you could write the required subdomains as needed_). 

Depending on the setup you'll need to adjust some variables in the files below.

The configuration of the platform is done through the `values.yaml` passed to helm. The important bit is the `CODER_ACCESS_URL` and `CODER_WILDCARD_ACCESS_URL` env vars and ingress config. They will define how clients can access the platform and their envs.

_values.yaml_
```yaml
coder:
  env:
    - name: CODER_PG_CONNECTION_URL
      valueFrom:
        secretKeyRef:
          name: coder-db-url
          key: url
    - name: CODER_ACCESS_URL
      value: "https://coder.org"
    - name: CODER_TELEMETRY
      value: "false"
    - name: CODER_WILDCARD_ACCESS_URL
      value: "*.coder.org"
    - name: CODER_AGENT_URL
      value:  "http://coder"
  service:
    type: ClusterIP
  ingress:
    enable: true
    host: "coder.org"
    wildcardHost: "*.coder.org"
    annotations:
      nginx.ingress.kubernetes.io/enable-cors: "true"
    tls:
      enable: true
```

Now we can deploy everything:
```shell
# create a namespace for our platform
kubectl create ns coder
kubectl config set-context --current --namespace coder

# postgres will be used by coder
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install coder-db bitnami/postgresql --namespace coder --set auth.username=coder --set auth.password=coder --set auth.database=coder --set persistence.size=10Gi

# create a secret for coder holding the db creds
kubectl create secret generic coder-db-url --from-literal=url="postgres://coder:coder@coder-db-postgresql.coder.svc.cluster.local:5432/coder?sslmode=disable"

# deploy coder
helm repo add coder-v2 https://helm.coder.com/v2
helm upgrade --install coder coder-v2/coder --namespace coder --values values.yaml
```

You should be able to access the management interface at `https://coder.org`. Create your admin user there and come back.


## The custom Kubernetes provider

We now need to register a provider for our environments. The default `Kubernetes` provider available is a good start, but we'll tweak it a bit to our needs. It's a single Terraform file defining the ressources to be created. It's quite long but the gist is that each environment will be composed of:
- 1 Pod that will execute our dev env, with configurable ressources allocations (CPU & RAM)
- 3 PersistantVolumeClaims
  - one for our home folder, mounted on `/root`
  - one for the dockerd daemon files, on `/var/lib/docker`  
  - one for linuxbrew at `/home/linuxbrew`

The file is quite long:
{{< details "__main.tf__" >}}

```h
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.7.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.18"
    }
  }
}

provider "coder" {
  feature_use_managed_variables = true
}


variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces)"
  default      = "coder"
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "Light machine (2 Cores)"
    value = "2"
  }
  option {
    name  = "Heavy Machine (8 Cores)"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory in GB"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
}

data "coder_parameter" "image" {
  name         = "Image"
  display_name = "Container Image"
  description  = "The base container image to use"
  default      = "k0rventen/code:0.1"
  icon         = "/icon/memory.svg"
  mutable      = true
  type         = "string"
}


provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = null
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os                     = "linux"
  arch                   = "amd64"
  startup_script_timeout = 180
  startup_script         = <<-EOT
    set -e
    fish /tmp/code/bootstrap.fish
  EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:9069?folder=/root/projects"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:9069/healthz"
    interval  = 3
    threshold = 10
  }
}





resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "4Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "docker" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-docker"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "linuxbrew" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-linuxbrew"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}


resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  spec {
    container {
      name              = "code-container"
      image             = "${data.coder_parameter.image.value}"
      image_pull_policy = "Always"
      command           = ["sh", "-c", replace(coder_agent.main.init_script,"https://coder.org","http://coder")]
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      security_context {
      privileged = "true"
    }
      resources {
        requests = {
          "cpu"    = "250m"
          "memory" = "512Mi"
        }
        limits = {
          "cpu"    = "${data.coder_parameter.cpu.value}"
          "memory" = "${data.coder_parameter.memory.value}Gi"
        }
      }
      volume_mount {
        mount_path = "/root"
        name       = "home"
        read_only  = false
      }
      volume_mount {
        mount_path = "/var/lib/docker"
        name       = "docker"
        read_only  = false
      }
      volume_mount {
        mount_path = "/home/linuxbrew"
        name       = "linuxbrew"
        read_only  = false
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }

    volume {
      name = "docker"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.docker.metadata.0.name
        read_only  = false
      }
    }

    volume {
      name = "linuxbrew"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.linuxbrew.metadata.0.name
        read_only  = false
      }
    }
  }
}
```
{{< /details >}}

_Note: One quirk of this setup is that due to our environment using self signed certificate, we have to replace the external URL (the one used to access the envs) by the internal one (the coder service inside the ns) for our envs to start properly. In a more realistic scenario, trusted CA certs would be used instead._

To deploy this provider to our Coder instance, we'll need the `coder` cli, available [here](https://github.com/coder/coder/releases). 
Depending on the exact setup (mainly due to self signed certificates), the login endpoint will vary, but the easiest is to port-forward the internal `coder` service and login through this:

```shell
# in a tab
kubectl port-forward svc/coder 8080:80

# in another tab, then follow the login procedure
coder login http://127.0.0.1:8080


# once logged in, in the same dir as `main.tf`, reply yes to questions
coder template create kube


# You should preview the resources that will be created for each env:
┌──────────────────────────────────────────────────┐
│ Template Preview                                 │
├──────────────────────────────────────────────────┤
│ RESOURCE                                         │
├──────────────────────────────────────────────────┤
│ kubernetes_persistent_volume_claim.docker        │
├──────────────────────────────────────────────────┤
│ kubernetes_persistent_volume_claim.home          │
├──────────────────────────────────────────────────┤
│ kubernetes_persistent_volume_claim.linuxbrew     │
├──────────────────────────────────────────────────┤
│ kubernetes_pod.main                              │
│ └─ main (linux, amd64)                           │
└──────────────────────────────────────────────────┘
```

## Accessing our environment

Now everything required to work directly into our cluster is deployed. 
We can now create a Workspace based on the provider we defined earlier:
![workspace](/coder-remote-env/workspace.png)

Wait for the pod to be created and the `code-server` button to become available.
Now we can work using a web browser from our thin & light laptop (or even a Raspberry Pi) with the power of a cluster:

{{< video src="/coder-remote-env/demo.mp4" type="video/mp4" >}}


## Disclaimer

This setup is loosely based on what is deployed and used daily at $job.
The main upsides are that :
- onboarding/updating/offboarding the environments are dead-easy,
- laptops are running way cooler, batteries last longer and builds are way faster, 
- and testing has very little friction due to the fact that we are right inside the cluster.

But there is some downsides:
- notably around security, our envs are running as privileged in the cluster (for dockerd), which might not be fine depending on the level of trust you want.
  One possible fix would be to switch to a rootless docker/podman, but as of time of writing, there are too many quirks when deploying such solutions.
- having the dev envs centralised means possibly a SPOF that could ruin everyone's day if something goes wrong with the platform or the cluster.
- it might require a certain level of maturity around containers, mainly around how networking is affected by a remote setup.