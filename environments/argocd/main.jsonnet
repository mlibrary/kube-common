local cluster = {
  argocd_hostname: error 'must provide "argocd_hostname" in /etc/cluster.json',
  argocd_client_secret: error 'must provide "argocd_client_secret" in /etc/cluster.json',
  cluster_name: error 'must provide "cluster_name" in /etc/cluster.json',
  github_teams: error 'must provide "github_teams" in /etc/cluster.json',
  dex_url: error 'must provide "dex_url" in /etc/cluster.json',
} + import '/etc/cluster.json';

{
  namespace: {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: { name: 'argocd' },
  },

  tanka_config: {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: { name: 'argocd-tanka-cmp' },
    data: {
      'plugin.yaml': std.manifestYamlDoc({
        apiVersion: 'argoproj.io/v1alpha1',
        kind: 'ConfigManagementPlugin',
        metadata: { name: 'tanka' },
        spec: {
          version: 'v1.0',
          allowConcurrency: 'true',
          lockRepo: 'false',
          discover: { fileName: './jsonnetfile.json' },
          generate: {
            command: ['sh', '-c'],
            args: ['/usr/local/bin/tk show --dangerous-allow-redirect $ARGOCD_ENV_TANKA_PATH'],
          },
        },
      }),
    },
  },

  ingress: {
    apiVersion: 'networking.k8s.io/v1',
    kind: 'Ingress',
    metadata: {
      name: 'argocd',
    },
    spec: {
      rules: [{
        host: cluster.argocd_hostname,
        http: { paths: [{
          path: '/',
          pathType: 'Prefix',
          backend: { service: {
            name: 'argocd-server',
            port: { name: 'http' },
          } },
        }] },
      }],
      tls: [{
        hosts: [cluster.argocd_hostname],
        secretName: 'argocd-tls',
      }],
    },
  },

  cert: {
    apiVersion: 'cert-manager.io/v1',
    kind: 'Certificate',
    metadata: { name: 'argocd-tls' },
    spec: {
      secretName: 'argocd-tls',
      dnsNames: [cluster.argocd_hostname],
      usages: ['digital signature', 'key encipherment'],
      issuerRef: {
        kind: 'ClusterIssuer',
        name: 'letsencrypt',
      },
    },
  },

  argocd: {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: {
      name: 'argocd',
    },
    spec: {
      project: 'default',
      syncPolicy: { automated: {} },
      destination: {
        server: 'https://kubernetes.default.svc',
        namespace: 'argocd',
      },
      source: {
        repoURL: 'https://argoproj.github.io/argo-helm',
        targetRevision: '5.9.1',
        chart: 'argo-cd',
        helm: {
          releaseName: 'argocd',
          values: std.manifestYamlDoc({
            configs: {
              params: { 'server.insecure': true },
              cm: {
                'admin.enabled': false,
                url: 'https://%s' % cluster.argocd_hostname,
                'oidc.config': std.manifestYamlDoc({
                  name: 'GitHub',
                  issuer: cluster.dex_url,
                  clientID: '%s-argocd' % cluster.cluster_name,
                  clientSecret: cluster.argocd_client_secret,
                }),
              },
              rbac: {
                'policy.csv': std.join('', ['g, %s, role:admin\n' % x for x in cluster.github_teams]),
              },
            },
            repoServer: {
              extraContainers: [{
                name: 'tanka-cmp',
                image: 'grafana/tanka:0.23.1',
                command: ['/var/run/argocd/argocd-cmp-server'],
                securityContext: {
                  runAsNonRoot: true,
                  runAsUser: 999,
                },
                volumeMounts: [{
                  name: 'var-files',
                  mountPath: '/var/run/argocd',
                }, {
                  name: 'plugins',
                  mountPath: '/home/argocd/cmp-server/plugins',
                }, {
                  name: 'tanka-cmp',
                  mountPath: '/home/argocd/cmp-server/config/plugin.yaml',
                  subPath: 'plugin.yaml',
                }, {
                  name: 'cluster-details',
                  mountPath: '/etc/cluster.json',
                  subPath: 'cluster.json',
                }, {
                  name: 'tmp',
                  mountPath: '/tmp',
                }],
              }],
              volumes: [{
                name: 'tanka-cmp',
                configMap: { name: 'argocd-tanka-cmp' },
              }, {
                name: 'cluster-details',
                secret: { secretName: 'cluster-details' },
              }],
            },
          }),
        },
      },
    },
  },
}
