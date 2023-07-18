Prometheus
==========

Add this to your app of apps:

```jsonnet
apiVersion: 'argoproj.io/v1alpha1',
kind: 'Application',
metadata: { name: 'prometheus' },
spec: {
  project: 'default',
  destination: { server: 'https://kubernetes.default.svc' },
  syncPolicy: { automated: { prune: true, selfHeal: true } },
  ignoreDifferences: [{
    kind: "ConfigMap",
    name: "prometheus-server-app",
    namespace: "prometheus",
    jsonPointers: ["/data"],
  }],
  source: {
    repoURL: 'https://github.com/mlibrary/kube-common',
    targetRevision: 'latest', // or 'stable' if you want slower updates
    path: '.',
    plugin: { env: [{
      name: 'TANKA_PATH',
      value: 'environments/prometheus',
    }]},
  },
},
```
