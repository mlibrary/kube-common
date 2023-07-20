Global Prometheus
=================

Add this to your app of apps (probably in the workshop cluster only):

```jsonnet
{
  global_prometheus_application: {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: { name: 'global-prometheus' },
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
          value: 'environments/global-prometheus',
        }]},
      },
    },
  },

  global_prometheus_config: {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: {
      name: 'monitoring-rules',
      namespace: 'global-prometheus',
    },
    data: {
      'alerts.yml': std.manifestYamlDoc({
        // Your alerts go here
      }),
    },
  },
}
```
