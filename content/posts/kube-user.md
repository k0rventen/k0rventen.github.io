---
title: "Add a new external user (or bot) in k8s"
date: 2021-06-22T11:41:36+02:00
description: "and do it properly with rbac"
tags: []
---

# what & why

If you need to give access to your cluster to either another human or for a given service, you should create a dedicated account for it. This is how to do it.


# how

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

