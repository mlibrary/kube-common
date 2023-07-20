local prometheus_server_version = 'v2.19.0';
local configmap_reload_version = 'v0.3.0';

local cluster = {
  argocd_hostname: error 'must provide "argocd_hostname" in /etc/cluster.json',
  argocd_client_secret: error 'must provide "argocd_client_secret" in /etc/cluster.json',
  cluster_name: error 'must provide "cluster_name" in /etc/cluster.json',
  dex_url: error 'must provide "dex_url" in /etc/cluster.json',
  github_teams: error 'must provide "github_teams" in /etc/cluster.json',
  is_host_cluster: false,
  prometheus_retention: '15d',
  global_prometheus_storage: '2Gi',
  alertmanagers: [],
  team_name: error 'must provide "team_name" in /etc/cluster.json',
} + import '/etc/cluster.json';

{
  namespace: {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: {
      name: 'global-prometheus',
    },
  },

  server: {
    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: 'prometheus-server',
      },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },
        selector: { matchLabels: {
          'app.kubernetes.io/name': 'prometheus-server',
          'app.kubernetes.io/part-of': 'global-prometheus',
        } },
        template: {
          metadata: { labels: {
            'app.kubernetes.io/name': 'prometheus-server',
            'app.kubernetes.io/component': 'server',
            'app.kubernetes.io/part-of': 'global-prometheus',
          } },
          spec: {
            serviceAccountName: 'prometheus-server',
            securityContext: {
              fsGroup: 65534,
              runAsGroup: 65534,
              runAsNonRoot: true,
              runAsUser: 65534,
            },
            containers: [{
              name: 'configmap-reload',
              image: 'jimmidyson/configmap-reload:%s' % configmap_reload_version,
              args: [
                '--volume-dir=/etc/config',
                '--webhook-url=http://127.0.0.1:9090/-/reload',
              ],
              volumeMounts: [{
                name: 'rules',
                mountPath: '/etc/config',
                readOnly: true,
              }],
            }, {
              name: 'prometheus-server',
              image: 'prom/prometheus:%s' % prometheus_server_version,
              ports: [{ containerPort: 9090 }],
              livenessProbe: {
                initialDelaySeconds: 30,
                timeoutSeconds: 30,
                httpGet: { port: 9090, path: '/-/healthy' },
              },
              readinessProbe: self.livenessProbe + {
                httpGet+: { path: '/-/ready' },
              },
              args: [
                '--storage.tsdb.retention.time=%s' % cluster.prometheus_retention,
                '--config.file=/etc/config/prometheus.yml',
                '--storage.tsdb.path=/data',
                '--web.console.libraries=/etc/prometheus/console_libraries',
                '--web.console.templates=/etc/prometheus/consoles',
                '--web.enable-lifecycle',
              ],
              volumeMounts: [{
                name: 'storage',
                mountPath: '/data',
              }, {
                name: 'config',
                mountPath: '/etc/config',
                readOnly: true,
              }, {
                name: 'rules',
                mountPath: '/etc/config/app',
                readOnly: true,
              }] + if std.length(cluster.alertmanagers) > 0 then [{
                name: 'tls',
                mountPath: '/tls',
                readOnly: true,
              }] else [],
            }],
            volumes: [{
              name: 'storage',
              persistentVolumeClaim: { claimName: 'prometheus-server' },
            }, {
              name: 'config',
              configMap: { name: 'prometheus-server' },
            }, {
              name: 'rules',
              configMap: { name: 'monitoring-rules' },
            }] + if std.length(cluster.alertmanagers) > 0 then [{
              name: 'tls',
              secret: { secretName: 'prometheus-tls' },
            }] else [],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'prometheus-server',
      },
      spec: {
        type: 'ClusterIP',
        ports: [{ port: 9090 }],
        selector: {
          'app.kubernetes.io/component': 'server',
          'app.kubernetes.io/part-of': 'global-prometheus',
        },
      },
    },

    service_account: {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: {
        name: 'prometheus-server',
      },
    },

    crb: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: {
        name: 'global-prometheus-server',
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'prometheus-server',
      },
      subjects: [{
        kind: 'ServiceAccount',
        name: 'prometheus-server',
        namespace: 'global-prometheus',
      }],
    },

    storage: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: {
        name: 'prometheus-server',
      },
      spec: {
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: cluster.global_prometheus_storage } },
      },
    },

    config: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: {
        name: 'prometheus-server',
      },
      data: {
        'prometheus.yml': std.manifestYamlDoc({
          global: {
            evaluation_interval: '10s',
            scrape_interval: '10s',
            scrape_timeout: '10s',
            external_labels: {
              team: cluster.team_name,
            },
          },
          rule_files: [
            '/etc/config/app/alerts.yml',
          ],
          [if std.length(cluster.alertmanagers) > 0 then 'alerting']: {
            alertmanagers: [{
              scheme: 'https',
              tls_config: {
                ca_file: '/tls/ca.crt',
                cert_file: '/tls/tls.crt',
                key_file: '/tls/tls.key',
              },
              static_configs: [{ targets: cluster.alertmanagers }]
            }]
          },
          scrape_configs: [{
            job_name: 'prometheus',
            static_configs: [{ targets: ['localhost:9090'] }],
          }, {
            job_name: 'federate-host-cluster',
            honor_labels: true,
            metrics_path: '/federate',
            kubernetes_sd_configs: [{ role: 'service' }],
            relabel_configs: [
              {
                action: 'keep',
                source_labels: ['__meta_kubernetes_namespace', '__meta_kubernetes_service_name'],
                regex: 'prometheus;prometheus-server|external-prometheus;.+',
              },
              {
                action: 'replace',
                target_label: 'cluster',
                source_labels: ['__meta_kubernetes_service_name'],
              },
              {
                action: 'keep',
                source_labels: ['__meta_kubernetes_service_name'],
                regex: 'host-kubernetes',
              },
            ],
            params: { 'match[]': [
              '{__name__=~".+:kube_pod_.+_resource_.+:sum"}',
            ] },
          }, {
            job_name: 'federate-vclusters',
            honor_labels: true,
            metrics_path: '/federate',
            kubernetes_sd_configs: [{ role: 'service' }],
            relabel_configs: [
              {
                action: 'keep',
                source_labels: ['__meta_kubernetes_namespace', '__meta_kubernetes_service_name'],
                regex: 'prometheus;prometheus-server|external-prometheus;.+',
              },
              {
                action: 'replace',
                target_label: 'cluster',
                source_labels: ['__meta_kubernetes_service_name'],
              },
              {
                action: 'replace',
                target_label: 'cluster',
                source_labels: ['__meta_kubernetes_namespace'],
                regex: 'prometheus',
                replacement: cluster.cluster_name,
              },
              {
                action: 'drop',
                source_labels: ['__meta_kubernetes_service_name'],
                regex: 'host-kubernetes',
              },
            ],

            params: { 'match[]': [
              '{__name__="namespace:kubelet_volume_stats_capacity:sum"}',
            ] },
          }],
        }),
      },
    },
  },
}
