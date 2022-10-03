---
title: "Add a new external user (or bot) in k8s"
date: 2022-10-03
description: "and do it properly with rbac"
tags: ["k8s","rbac","security"]
---

<!-- TOC -->

- [what & why](#what--why)
- [how](#how)
    - [A word on RBAC](#a-word-on-rbac)
    - [Users for humans](#users-for-humans)
    - [ServiceAccounts for non humans [Updated March 2022]](#serviceaccounts-for-non-humans-updated-march-2022)
        - [Note for kubernetes >= 1.25](#note-for-kubernetes--125)
    - [ServiceAccounts [OG July 2021]](#serviceaccounts-og-july-2021)
    - [Impersonating other users](#impersonating-other-users)

<!-- /TOC -->

# what & why

If you need to give access to your cluster to either another human or for a given service, you should create a dedicated account for it. This is how to do it.

To authenticate, humans can use both the `ServiceAccount` resource (through a token) and as `Users` (trough a key and crt). Bots or non-human things should only use `ServiceAccounts`.


# how

## A word on RBAC

Role Based Access Control (RBAC) is a way of separating users from privileges, by introducing `roles`. Instead of linking users to privlieges directly (Jake has read access on the pods), we link users to roles, which have a given set of privileges (Jake is a developper, and the developper role has read access on pods.). We can now attach multiple users to a role, and albeit it complexifies somewhat the number of ressources, 

In Kubernetes, we need to create 3 resources when creating permissions:
- a `User` (or `ServiceAccount`)
- a `Role` (bound to a given namespace) or `clusterRole` (spans through the cluster) that contains privileges,
- a `RoleBinding` or `ClusterRoleBinding`, that will bind our subject to the role.


[k8s doc on RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## Users for humans

_Note: A part of the procedure should be done on a cluster's node, as we need access to the control plane's key & certificate._

First, we'll create a key for our user, here named jake:

```
openssl genrsa -out jake.key 2048
```

Now, we'll create a CSR (Certificate Signing Request) that our cluster will sign:

```
openssl req \
  -new \
  -subj "/CN=jake" \
  -key jake.key \
  -out jake.csr
```

This will create a .csr file, that we'll sign using the certificate of the cluster:

_Note: some k8s distros do not store their pki file in /etc/kubernetes, check with their respective documentation on where they are._

```
openssl x509 -req \
  -in jake.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -out jake.crt -days 365
```

This creates a `jake.crt`. 

Now we can use the `.crt` and `.key` that were created as an authentification method for our cluster. We'll copy those to our machine. Let's create a new user with the new auth method:

```
kubectl config set-credentials jake --client-certificate=$PWD/jake.crt --client-key=$PWD/jake.key
```

And now create a context with our new user
```
kubectl config set-context jake-on-dev-cluster --cluster=dev-cluster --user=jake
```

##  ServiceAccounts for non humans [Updated March 2022]

If you are using a fairly recent (>= 1.22) version of kubectl which allows the creation of ressources through `kubectl create`, it's now super easy to do so:

Create a new service account named `bot1`:

```
kubectl create sa bot1
```

now, create a role (or cluster role) with the wanted permissions. Let's say that the bot which will be using the service account will only need to get, list and watch pods and deployments in his namespace (default). (Further documentation can be retrieved using `kubectl create role -h`)

```
kubectl create role bot1-pods --verb=get,list,watch --resource=pods,deploy
```

Now, we'll just bind the role (or cluster role) with our service account, using a rolebinding:

_the service account must be specified using namespace:sa_
```
kubectl create rolebinding --serviceaccount default:bot1 --role bot1-pods bot1-pods
```

nice ! Using only 3 commands we were able to create and configure our service account. Of course if further configuration on the role is needed (to have greater granularity), we can create a proper manifest or edit the ressource, but it gives us a good base to start with.

### Note for kubernetes >= 1.25
Since kubernetes 1.25 (and 1.24 on some distros), when creating a serviceaccount, kubernetes does not create an associated token containing a token. Instead, we should use `Tokens`:

```
kubectl create token <serviceaccount_name>
```
which will return a JWT token that can be used.


To retrieve the token linked to the service account, we can simply search the associated secret:

```
# using jq
kubectl get secrets -o json | jq '.items[] | select(.metadata.name|test("bot1-token.*")) | .data.token'

# or using kubectl's jsonpath
kubectl get -o jsonpath="{.data.token}" secret (kubectl get sa bot1 -o jsonpath="{.secrets[0]['name']}")
```

## ServiceAccounts [OG July 2021]

First, create a new serviceaccount, clusterrole (or role) & clusterrole binding (or role binding). Do not forget to change the permissions according to your needs : 


```yml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: readonly
  namespace: <ns>
---
# RB for the SA
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: readonly
subjects:
- kind: ServiceAccount
  name: readonly
  namespace: <ns>
roleRef:
  kind: ClusterRole
  name: readonly
  apiGroup: rbac.authorization.k8s.io

---
# Permissions for the SA
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: readonly
rules:
- apiGroups: [''] # core API
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
```

apply it `k apply -f user.yml`

Now grab the secret for that serviceaccount:

```
k get secrets | grep readonly
```

Tht will be something like `readonly-token-wkp94`.
Then grab the secret's token, __and decode it from b64__

```
k get -o yaml secrets readonly-token-wkp94 | grep token:

echo <token> | base64 -d
```

You can now pass this token to whatever you need to. 

If you need to setup a new human access (using kubectl for example) :

```
kubectl config set-credentials newuser --token="<token>"

kubectl config set-context newuser-access --cluster=<clustername> --user=newuser

kubectl config use-context newuser-access
```

you should now be able to use kubectl, but with the permissions of that serviceAccount.


## Impersonating other users

Using impersonation (which requires the `impersonate` verb on `users`, `groups`, and `serviceaccounts` in the core API group), we can test the newly created service account's permissions: 

can the account get pods ? 
```
> kubectl auth can-i --as "system:serviceaccount:namespace:serviceaccount_name" get pods
yes
```

can we get secrets ? 

```
> kubectl auth can-i --as "user" get secrets
no
```

What does this account has access to:

```
> kubectl auth can-i --as "user" --list
Resources                                       Non-Resource URLs                     Resource Names   Verbs
deployments.apps                                []                                    []               [create get list update patch]
statefulsets.apps                               []                                    []               [create get list update patch]
```