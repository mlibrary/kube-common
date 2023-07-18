local prometheus_server_version = 'v2.19.0';
local configmap_reload_version = 'v0.3.0';
local blackbox_version = 'v0.23.0';
local pushgateway_version = 'v1.5.1';
local kube_state_metrics_version = 'v1.9.7';

local cluster = {
  argocd_hostname: error 'must provide "argocd_hostname" in /etc/cluster.json',
  argocd_client_secret: error 'must provide "argocd_client_secret" in /etc/cluster.json',
  cluster_name: error 'must provide "cluster_name" in /etc/cluster.json',
  dex_url: error 'must provide "dex_url" in /etc/cluster.json',
  github_teams: error 'must provide "github_teams" in /etc/cluster.json',
  is_host_cluster: false,
  prometheus_retention: '15d',
  prometheus_storage: '32Gi',
  alertmanagers: [],
  team_name: error 'must provide "team_name" in /etc/cluster.json',
} + import '/etc/cluster.json';

{
  namespace: {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: {
      name: 'prometheus',
    },
  },

  server: {
    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: 'prometheus-server',
        namespace: 'prometheus',
      },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },
        selector: { matchLabels: {
          'app.kubernetes.io/name': 'prometheus-server',
          'app.kubernetes.io/part-of': 'prometheus',
        } },
        template: {
          metadata: { labels: {
            'app.kubernetes.io/name': 'prometheus-server',
            'app.kubernetes.io/component': 'server',
            'app.kubernetes.io/part-of': 'prometheus',
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
                name: 'config-kube',
                mountPath: '/etc/config',
                readOnly: true,
              }, {
                name: 'config-app',
                mountPath: '/etc/config/app',
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
                name: 'config-kube',
                mountPath: '/etc/config',
                readOnly: true,
              }, {
                name: 'config-app',
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
              name: 'config-kube',
              configMap: { name: 'prometheus-server-kube' },
            }, {
              name: 'config-app',
              configMap: { name: 'prometheus-server-app' },
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
        namespace: 'prometheus',
      },
      spec: {
        type: 'ClusterIP',
        ports: [{ port: 9090 }],
        selector: {
          'app.kubernetes.io/component': 'server',
          'app.kubernetes.io/part-of': 'prometheus',
        },
      },
    },

    service_account: {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: {
        name: 'prometheus-server',
        namespace: 'prometheus',
      },
    },

    crb: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: {
        name: 'prometheus-server',
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'prometheus-server',
      },
      subjects: [{
        kind: 'ServiceAccount',
        name: 'prometheus-server',
        namespace: 'prometheus',
      }],
    },

    cr: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: {
        name: 'prometheus-server',
      },
      rules: [{
        apiGroups: [''],
        resources: [
          'nodes',
          'nodes/proxy',
          'nodes/metrics',
          'services',
          'endpoints',
          'pods',
          'ingresses',
          'configmaps',
        ],
        verbs: ['get', 'list', 'watch'],
      }, {
        apiGroups: ['extensions'],
        resources: ['ingresses/status', 'ingresses'],
        verbs: ['get', 'list', 'watch'],
      }, {
        nonResourceURLs: ['/metrics'],
        verbs: ['get'],
      }],
    },

    storage: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: {
        name: 'prometheus-server',
        namespace: 'prometheus',
      },
      spec: {
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: cluster.prometheus_storage } },
      },
    },

    kube_config: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: {
        name: 'prometheus-server-kube',
        namespace: 'prometheus',
      },
      data: {
        'recording_rules.yml': std.manifestYamlDoc({
          groups: [{
            name: 'kube_resources',
            rules: [{
              record: 'namespace:kubelet_volume_stats_capacity:sum',
              expr: 'sum by(namespace)(kubelet_volume_stats_capacity_bytes)',
            }],
          }],
        }),
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
            '/etc/config/recording_rules.yml',
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
            job_name: 'kubernetes-apiservers',
            kubernetes_sd_configs: [{ role: 'endpoints' }],
            scheme: 'https',
            bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token',
            tls_config: {
              ca_file: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
              insecure_skip_verify: true,
            },
            relabel_configs: [{
              action: 'keep',
              regex: 'default;kubernetes;https',
              source_labels: [
                '__meta_kubernetes_namespace',
                '__meta_kubernetes_service_name',
                '__meta_kubernetes_endpoint_port_name',
              ],
            }],
          }, {
            job_name: 'kubernetes-nodes',
            kubernetes_sd_configs: [{ role: 'node' }],
            scheme: 'https',
            bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token',
            tls_config: {
              ca_file: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
              insecure_skip_verify: true,
            },
            relabel_configs: [{
              // {__meta_kubernetes_node_label_hello=""} -> {hello=""}
              action: 'labelmap',
              regex: '__meta_kubernetes_node_label_(.+)',
            }, {
              // Scrape the kubernetes API directly.
              action: 'replace',
              target_label: '__address__',
              replacement: 'kubernetes.default.svc:443',
            }, {
              // Metrics for worker-0.com at /api/v1/nodes/worker-0.com/proxy/metrics
              action: 'replace',
              target_label: '__metrics_path__',
              source_labels: ['__meta_kubernetes_node_name'],
              regex: '(.+)',
              replacement: '/api/v1/nodes/$1/proxy/metrics',
            }],
          }, {
            job_name: 'kubernetes-nodes-cadvisor',
            kubernetes_sd_configs: [{ role: 'node' }],
            scheme: 'https',
            bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token',
            tls_config: {
              ca_file: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
              insecure_skip_verify: true,
            },
            relabel_configs: [{
              // {__meta_kubernetes_node_label_hello=""} -> {hello=""}
              action: 'labelmap',
              regex: '__meta_kubernetes_node_label_(.+)',
            }, {
              // Scrape the kubernetes API directly.
              action: 'replace',
              target_label: '__address__',
              replacement: 'kubernetes.default.svc:443',
            }, {
              // Metrics for worker-0.com at /api/v1/nodes/worker-0.com/proxy/metrics
              action: 'replace',
              target_label: '__metrics_path__',
              source_labels: ['__meta_kubernetes_node_name'],
              regex: '(.+)',
              replacement: '/api/v1/nodes/$1/proxy/metrics/cadvisor',
            }],
          }, {
            job_name: 'kubernetes-service-endpoints',
            kubernetes_sd_configs: [{ role: 'endpoints' }],
            relabel_configs: [{
              // Keep service endpoints with annotation prometheus.io/scrape: "true"
              action: 'keep',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_scrape'],
              regex: 'true',
            }, {
              // Scheme can be http or https; ask prometheus.io/scheme
              action: 'replace',
              target_label: '__scheme__',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_scheme'],
              regex: '(https?)',
            }, {
              // Path is /metrics or prometheus.io/path
              action: 'replace',
              target_label: '__metrics_path__',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_path'],
              regex: '(.+)',
            }, {
              // Replace the port in the address if prometheus.io/port
              action: 'replace',
              target_label: '__address__',
              source_labels: [
                '__address__',
                '__meta_kubernetes_service_annotation_prometheus_io_port',
              ],
              // (original_addr):original_port;(new_port)
              regex: '([^:]+)(?::\\d+)?;(\\d+)',
              replacement: '$1:$2',
            }, {
              action: 'labelmap',
              regex: '__meta_kubernetes_service_label_(.+)',
            }, {
              action: 'replace',
              target_label: 'kubernetes_namespace',
              source_labels: ['__meta_kubernetes_namespace'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_name',
              source_labels: ['__meta_kubernetes_service_name'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_node',
              source_labels: ['__meta_kubernetes_pod_node_name'],
            }],
          }, {
            job_name: 'kubernetes-service-endpoints-slow',
            scrape_interval: '5m',
            scrape_timeout: '30s',
            kubernetes_sd_configs: [{ role: 'endpoints' }],
            relabel_configs: [{
              // Keep service endpoints with annotation prometheus.io/scrape-slow: "true"
              action: 'keep',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_scrape_slow'],
              regex: 'true',
            }, {
              // Scheme can be http or https; ask prometheus.io/scheme
              action: 'replace',
              target_label: '__scheme__',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_scheme'],
              regex: '(https?)',
            }, {
              // Path is /metrics or prometheus.io/path
              action: 'replace',
              target_label: '__metrics_path__',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_path'],
              regex: '(.+)',
            }, {
              // Replace the port in the address if prometheus.io/port
              action: 'replace',
              target_label: '__address__',
              source_labels: [
                '__address__',
                '__meta_kubernetes_service_annotation_prometheus_io_port',
              ],
              // (original_addr):original_port;(new_port)
              regex: '([^:]+)(?::\\d+)?;(\\d+)',
              replacement: '$1:$2',
            }, {
              action: 'labelmap',
              regex: '__meta_kubernetes_service_label_(.+)',
            }, {
              action: 'replace',
              target_label: 'kubernetes_namespace',
              source_labels: ['__meta_kubernetes_namespace'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_name',
              source_labels: ['__meta_kubernetes_service_name'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_node',
              source_labels: ['__meta_kubernetes_pod_node_name'],
            }],
          }, {
            job_name: 'kubernetes-pods',
            kubernetes_sd_configs: [{ role: 'pod' }],
            relabel_configs: [{
              // Keep pods with annotation prometheus.io/scrape: "true"
              action: 'keep',
              source_labels: ['__meta_kubernetes_pod_annotation_prometheus_io_scrape'],
              regex: 'true',
            }, {
              // Path is /metrics or prometheus.io/path
              action: 'replace',
              target_label: '__metrics_path__',
              source_labels: ['__meta_kubernetes_pod_annotation_prometheus_io_path'],
              regex: '(.+)',
            }, {
              // Replace the port in the address if prometheus.io/port
              action: 'replace',
              target_label: '__address__',
              source_labels: [
                '__address__',
                '__meta_kubernetes_pod_annotation_prometheus_io_port',
              ],
              // (original_addr):original_port;(new_port)
              regex: '([^:]+)(?::\\d+)?;(\\d+)',
              replacement: '$1:$2',
            }, {
              action: 'labelmap',
              regex: '__meta_kubernetes_pod_label_(.+)',
            }, {
              action: 'replace',
              target_label: 'kubernetes_namespace',
              source_labels: ['__meta_kubernetes_namespace'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_pod_name',
              source_labels: ['__meta_kubernetes_pod_name'],
            }],
          }, {
            job_name: 'kubernetes-pods-slow',
            scrape_interval: '5m',
            scrape_timeout: '30s',
            kubernetes_sd_configs: [{ role: 'pod' }],
            relabel_configs: [{
              // Keep pods with annotation prometheus.io/scrape-slow: "true"
              action: 'keep',
              source_labels: ['__meta_kubernetes_pod_annotation_prometheus_io_scrape_slow'],
              regex: 'true',
            }, {
              // Path is /metrics or prometheus.io/path
              action: 'replace',
              target_label: '__metrics_path__',
              source_labels: ['__meta_kubernetes_pod_annotation_prometheus_io_path'],
              regex: '(.+)',
            }, {
              // Replace the port in the address if prometheus.io/port
              action: 'replace',
              target_label: '__address__',
              source_labels: [
                '__address__',
                '__meta_kubernetes_pod_annotation_prometheus_io_port',
              ],
              // (original_addr):original_port;(new_port)
              regex: '([^:]+)(?::\\d+)?;(\\d+)',
              replacement: '$1:$2',
            }, {
              action: 'labelmap',
              regex: '__meta_kubernetes_pod_label_(.+)',
            }, {
              action: 'replace',
              target_label: 'kubernetes_namespace',
              source_labels: ['__meta_kubernetes_namespace'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_pod_name',
              source_labels: ['__meta_kubernetes_pod_name'],
            }],
          }, {
            job_name: 'pushgateway',
            honor_labels: true,
            kubernetes_sd_configs: [{ role: 'service' }],
            relabel_configs: [{
              // Keep services with annotation prometheus.io/probe: pushgateway
              action: 'keep',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_probe'],
              regex: 'pushgateway',
            }],
          }, {
            job_name: 'http-probes',
            metrics_path: '/probe',
            kubernetes_sd_configs: [{ role: 'service' }],
            params: { module: ['http_2xx'] },
            relabel_configs: [{
              // Keep services with annotation prometheus.io/probe: true
              action: 'keep',
              source_labels: ['__meta_kubernetes_service_annotation_prometheus_io_probe'],
              regex: 'true',
            }, {
              // blackbox/probe?target=__address__
              action: 'replace',
              target_label: '__param_target',
              source_labels: ['__address__'],
            }, {
              // Don't scrape the service; scrape blackbox/probe
              action: 'replace',
              target_label: '__address__',
              replacement: 'blackbox:9115',
            }, {
              // {instance="__address__"}
              action: 'replace',
              target_label: 'instance',
              source_labels: ['__param_target'],
            }, {
              action: 'labelmap',
              regex: '__meta_kubernetes_service_label_(.+)',
            }, {
              action: 'replace',
              target_label: 'kubernetes_namespace',
              source_labels: ['__meta_kubernetes_namespace'],
            }, {
              action: 'replace',
              target_label: 'kubernetes_name',
              source_labels: ['__meta_kubernetes_service_name'],
            }],
          }],
        }),
      },
    },

    app_config: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: {
        name: 'prometheus-server-app',
        namespace: 'prometheus',
      },
      data: {
        'alerts.yml': std.manifestYamlDoc({}),
      },
    },
  },

  blackbox: {
    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: 'blackbox',
        namespace: 'prometheus',
      },
      spec: {
        replicas: 1,
        selector: { matchLabels: {
          'app.kubernetes.io/name': 'blackbox',
          'app.kubernetes.io/part-of': 'prometheus',
        } },
        template: {
          metadata: { labels: {
            'app.kubernetes.io/name': 'blackbox',
            'app.kubernetes.io/component': 'blackbox-exporter',
            'app.kubernetes.io/part-of': 'prometheus',
          } },
          spec: {
            containers: [{
              name: 'blackbox',
              image: 'prom/blackbox-exporter:%s' % blackbox_version,
              ports: [{ containerPort: 9115 }],
            }],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'blackbox',
        namespace: 'prometheus',
      },
      spec: {
        type: 'ClusterIP',
        ports: [{ port: 9115 }],
        selector: {
          'app.kubernetes.io/component': 'blackbox-exporter',
          'app.kubernetes.io/part-of': 'prometheus',
        },
      },
    },
  },

  pushgateway: {
    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: 'pushgateway',
        namespace: 'prometheus',
      },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },
        selector: { matchLabels: {
          'app.kubernetes.io/name': 'pushgateway',
          'app.kubernetes.io/part-of': 'prometheus',
        } },
        template: {
          metadata: { labels: {
            'app.kubernetes.io/name': 'pushgateway',
            'app.kubernetes.io/component': 'pushgateway',
            'app.kubernetes.io/part-of': 'prometheus',
          } },
          spec: {
            containers: [{
              name: 'pushgateway',
              image: 'prom/pushgateway:%s' % pushgateway_version,
              ports: [{ containerPort: 9091 }],
              args: ['--persistence.file=/archive/pushgateway'],
              volumeMounts: [{
                name: 'storage',
                mountPath: '/archive',
              }],
            }],
            volumes: [{
              name: 'storage',
              persistentVolumeClaim: { claimName: 'pushgateway' },
            }],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'pushgateway',
        namespace: 'prometheus',
        annotations: { 'prometheus.io/probe': 'pushgateway' },
      },
      spec: {
        type: 'ClusterIP',
        ports: [{ port: 9091 }],
        selector: {
          'app.kubernetes.io/component': 'pushgateway',
          'app.kubernetes.io/part-of': 'prometheus',
        },
      },
    },

    storage: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: {
        name: 'pushgateway',
        namespace: 'prometheus',
      },
      spec: {
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: '100Mi' } },
      },
    },
  },

  kube_state_exporter: {
    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: 'kube-state-metrics',
        namespace: 'prometheus',
      },
      spec: {
        replicas: 1,
        selector: { matchLabels: {
          'app.kubernetes.io/name': 'kube-state-metrics',
          'app.kubernetes.io/part-of': 'prometheus',
        } },
        template: {
          metadata: { labels: {
            'app.kubernetes.io/name': 'kube-state-metrics',
            'app.kubernetes.io/component': 'kube-state-exporter',
            'app.kubernetes.io/part-of': 'prometheus',
          } },
          spec: {
            serviceAccountName: 'kube-state-metrics',
            securityContext: {
              fsGroup: 65534,
              runAsGroup: 65534,
              runAsUser: 65534,
            },
            containers: [{
              name: 'kube-state-metrics',
              image: 'quay.io/coreos/kube-state-metrics:%s' % kube_state_metrics_version,
              ports: [{ containerPort: 8080 }],
              livenessProbe: {
                initialDelaySeconds: 5,
                timeoutSeconds: 5,
                httpGet: { port: 8080, path: '/healthz' },
              },
              readinessProbe: self.livenessProbe {
                httpGet+: { path: '/' },
              },
              args: [
                '--collectors=certificatesigningrequests',
                '--collectors=configmaps',
                '--collectors=cronjobs',
                '--collectors=daemonsets',
                '--collectors=deployments',
                '--collectors=endpoints',
                '--collectors=horizontalpodautoscalers',
                '--collectors=ingresses',
                '--collectors=jobs',
                '--collectors=limitranges',
                '--collectors=mutatingwebhookconfigurations',
                '--collectors=namespaces',
                '--collectors=networkpolicies',
                '--collectors=nodes',
                '--collectors=persistentvolumeclaims',
                '--collectors=persistentvolumes',
                '--collectors=poddisruptionbudgets',
                '--collectors=pods',
                '--collectors=replicasets',
                '--collectors=replicationcontrollers',
                '--collectors=resourcequotas',
                '--collectors=secrets',
                '--collectors=services',
                '--collectors=statefulsets',
                '--collectors=storageclasses',
                '--collectors=validatingwebhookconfigurations',
                '--collectors=volumeattachments',
              ],
            }],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'kube-state-metrics',
        namespace: 'prometheus',
        annotations: { 'prometheus.io/scrape': 'true' },
      },
      spec: {
        type: 'ClusterIP',
        ports: [{ port: 8080 }],
        selector: {
          'app.kubernetes.io/component': 'kube-state-exporter',
          'app.kubernetes.io/part-of': 'prometheus',
        },
      },
    },

    service_account: {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: {
        name: 'kube-state-metrics',
        namespace: 'prometheus',
      },
    },

    crb: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: {
        name: 'kube-state-metrics',
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'kube-state-metrics',
      },
      subjects: [{
        kind: 'ServiceAccount',
        name: 'kube-state-metrics',
        namespace: 'prometheus',
      }],
    },

    cr: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: {
        name: 'kube-state-metrics',
      },
      rules: [{
        apiGroups: ['certificates.k8s.io'],
        resources: ['certificatesigningrequests'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['configmaps'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['batch'],
        resources: ['cronjobs'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['extensions', 'apps'],
        resources: ['daemonsets'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['extensions', 'apps'],
        resources: ['deployments'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['endpoints'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['autoscaling'],
        resources: ['horizontalpodautoscalers'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['extensions', 'networking.k8s.io'],
        resources: ['ingresses'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['batch'],
        resources: ['jobs'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['limitranges'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['admissionregistration.k8s.io'],
        resources: ['mutatingwebhookconfigurations'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['namespaces'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['networking.k8s.io'],
        resources: ['networkpolicies'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['nodes'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['persistentvolumeclaims'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['persistentvolumes'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['policy'],
        resources: ['poddisruptionbudgets'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['pods'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['extensions', 'apps'],
        resources: ['replicasets'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['replicationcontrollers'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['resourcequotas'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['secrets'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: [''],
        resources: ['services'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['apps'],
        resources: ['statefulsets'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['storage.k8s.io'],
        resources: ['storageclasses'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['admissionregistration.k8s.io'],
        resources: ['validatingwebhookconfigurations'],
        verbs: ['list', 'watch'],
      }, {
        apiGroups: ['storage.k8s.io'],
        resources: ['volumeattachments'],
        verbs: ['list', 'watch'],
      }],
    },
  },
}
