local argocd_helm_chart_version = '~8.5';

// https://hub.docker.com/r/grafana/tanka/tags
local tanka_container_image_version = '0.28.2';

local cluster = {
  argocd_hostname: error 'must provide "argocd_hostname" in /etc/cluster.json',
  argocd_client_secret: error 'must provide "argocd_client_secret" in /etc/cluster.json',
  cluster_name: error 'must provide "cluster_name" in /etc/cluster.json',
  dex_url: error 'must provide "dex_url" in /etc/cluster.json',
  github_teams: error 'must provide "github_teams" in /etc/cluster.json',
  is_host_cluster: false,
} + import '/etc/cluster.json';

{
  namespace: {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: { name: 'argocd' },
  },

  default_resources: {
    apiVersion: 'v1',
    kind: 'LimitRange',
    metadata: { name: 'default-container-resources' },
    spec: {
      limits: [{
        type: 'Container',
        defaultRequest: {
          cpu: '100m',
          memory: '128Mi',
          'ephemeral-storage': '128Mi',
        },
        default: {
          cpu: '250m',
          memory: '512Mi',
          'ephemeral-storage': '512Mi',
        },
      }],
    },
  },

  // It doesn't quite fit for the clusterrolebindings to be here, but
  // these are required for every cluster to work, and they make sense
  // under the wider umbrella of "things a cluster needs in order for it
  // to work properly." Nothing to do with argocd specifically, but this
  // is required for kubectl to work, and it has to live somewhere.
  role_bindings: [{
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      name: 'github-%s' % std.splitLimitR(team_name, ':', 1)[1],
    },
    roleRef: {
      name: 'cluster-admin',
      kind: 'ClusterRole',
      apiGroup: 'rbac.authorization.k8s.io',
    },
    subjects: [{
      name: team_name,
      kind: 'Group',
      apiGroup: 'rbac.authorization.k8s.io',
    }],
  } for team_name in cluster.github_teams],

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
      annotations: {
        'cert-manager.io/cluster-issuer': 'letsencrypt',
        [if cluster.is_host_cluster then
          'nginx.ingress.kubernetes.io/ssl-passthrough']: 'true',
      },
    },
    spec: {
      ingressClassName: 'nginx',
      rules: [{
        host: cluster.argocd_hostname,
        http: { paths: [{
          path: '/',
          pathType: 'Prefix',
          backend: { service: {
            name: 'argocd-server',
            port: { name: if cluster.is_host_cluster then 'https' else 'http' },
          } },
        }] },
      }],
      tls: [{
        hosts: [cluster.argocd_hostname],
        secretName: if cluster.is_host_cluster then 'argocd-secret' else 'argocd-tls',
      }],
    },
  },

  argocd: {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: {
      name: 'argocd-helm-chart',
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
        targetRevision: argocd_helm_chart_version,
        chart: 'argo-cd',
        helm: {
          releaseName: 'argocd',
          values: std.manifestYamlDoc({
            configs: {
              [if !cluster.is_host_cluster then 'params']: {
                'server.insecure': true,
              },
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
            controller: {
              resources: {
                requests: {
                  cpu: '250m',
                  memory: '256Mi',
                },
                limits: {
                  cpu: '1500m',
                  memory: '2Gi',
                },
              },
            },
            repoServer: {
              existingVolumes: {
                ramdisk(capacity):: { emptyDir: { medium: 'Memory', sizeLimit: capacity } },

                // var-files should possibly be a PVC or an ephemeral volume provisioned by Rook
                varFiles: self.ramdisk('1Gi'),
                helmWorkingDir: self.ramdisk('100Mi'),
                tmp: self.ramdisk('100Mi'),
                plugins: self.ramdisk('100Mi'),
              },
              // The memory limit is high for now to account for all of the ramdisk
              resources: {
                requests: {
                  cpu: '50m',
                  memory: '256Mi',
                },
                limits: {
                  cpu: '1',
                  memory: '2Gi',
                },
              },
              extraContainers: [{
                name: 'tanka-cmp',
                image: 'grafana/tanka:%s' % tanka_container_image_version,
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
                  name: 'cmp-tmp',
                  mountPath: '/tmp',
                }],
              }],
              volumes: [{
                name: 'tanka-cmp',
                configMap: { name: 'argocd-tanka-cmp' },
              }, {
                name: 'cluster-details',
                secret: { secretName: 'cluster-details' },
              }, {
                name: 'cmp-tmp',
                emptyDir: {
                  medium: 'Memory',
                  sizeLimit: '100Mi',
                }
              }],
            },
          }),
        },
      },
    },
  },
}
