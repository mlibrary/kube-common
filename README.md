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
