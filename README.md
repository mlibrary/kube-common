Common config repo
==================

Our intention is to keep the `latest` and `stable` branches mostly in
sync, but we'll always change `latest` before doing anything with
`stable`.

To use one of these environments in your config repo, add each
environment to your app of apps:

```jsonnet
local app = {
  name: 'name-of-kubernetes-application-object',
  path: 'environments/thing-to-install',
  branch: 'latest', // or 'stable' if you want slower updates
},

apiVersion: 'argoproj.io/v1alpha1',
kind: 'Application',
metadata: { name: app.name },
spec: {
  project: 'default',
  destination: { server: 'https://kubernetes.default.svc' },
  syncPolicy: { automated: { prune: true, selfHeal: true } },
  source: {
    repoURL: 'https://github.com/mlibrary/kube-common',
    targetRevision: app.branch,
    path: '.',
    plugin: { env: [{
      name: 'TANKA_PATH',
      value: app.path,
    }]},
  },
},
```

Latest versus stable
--------------------

Changes to the `latest` branch can happen anytime, but changes to the
`stable` branch will always happen after an interval. So if you pull
from `latest` in a workshop cluster and `stable` in a production
cluster, then the change will happen in the workshop before it happens
in production.

We should set up the stable branch to follow latest automatically, but
right now, it's done manually:

```sh
git pull
git checkout stable
git rebase latest
git push -f
git checkout latest
```
