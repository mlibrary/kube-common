// https://artifacthub.io/packages/helm/bitnami-labs/sealed-secrets
local sealed_secrets_heml_chart_version = '^2.7.0';

{
  sealed_secrets: {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: {
      name: 'sealed-secrets-helm-chart',
      labels: { 'argocd.argoproj.io/instance': 'app-of-apps' },
    },
    spec: {
      project: 'default',
      syncPolicy: { automated: { } },
      destination: {
        server: 'https://kubernetes.default.svc',
        namespace: 'kube-system',
      },
      source: {
        repoURL: 'https://bitnami-labs.github.io/sealed-secrets',
        targetRevision: sealed_secrets_heml_chart_version,
        chart: 'sealed-secrets',
        helm: { releaseName: 'sealed-secrets-controller' },
      },
    },
  },
}
