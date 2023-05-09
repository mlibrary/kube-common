Sealed Secrets
==============

Add this to your app of apps:

```jsonnet
apiVersion: 'argoproj.io/v1alpha1',
kind: 'Application',
metadata: { name: 'sealed-secrets-common' },
spec: {
  project: 'default',
  destination: { server: 'https://kubernetes.default.svc' },
  syncPolicy: { automated: { prune: true, selfHeal: true } },
  source: {
    repoURL: 'https://github.com/mlibrary/kube-common',
    targetRevision: 'latest', // or 'stable' if you want slower updates
    path: '.',
    plugin: { env: [{
      name: 'TANKA_PATH',
      value: 'environments/sealed-secrets',
    }]},
  },
},
```
