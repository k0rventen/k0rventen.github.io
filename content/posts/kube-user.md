---
title: "Add a new external user (or bot) in k8s"
date: 2022-02-22
description: "and do it properly with rbac"
tags: ["k8s","rbac","security"]
---

# what & why

If you need to give access to your cluster to either another human or for a given service, you should create a dedicated account for it. This is how to do it.


# how

### 2022 update

Due to newer version of kubectl allowing the creation of ressources through `kubectl create`, it's now super easy to do so:

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

Using impersonnation, we can test the newly created service account's permissions: 

can the account get pods ? 
```
> kubectl auth can-i --as "system:serviceaccount:default:bot1" get pods
yes
```

can we get secrets ? 

```
> kubectl auth can-i --as "system:serviceaccount:default:bot1" get secrets
no
```

nice ! Using only 3 commands we were able to create and configure our service account. Of course if further configuration on the role is needed (to have greated granularity), we can create a proper manifest or edit the ressource, but it gives us a good base to start with.

To retrieve the token linked to the service account, we can simply search the associated secret:

```
# using jq
kubectl get secrets -o json | jq '.items[] | select(.metadata.name|test("bot1-token.*")) | .data.token'

# or using kubectl's jsonpath
kubectl get -o jsonpath="{.data.token}" secret (kubectl get sa bot1 -o jsonpath="{.secrets[0]['name']}")
```

### OG post (July 2021)

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

