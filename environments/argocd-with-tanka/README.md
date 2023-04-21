Argocd with Tanka
=================

Add this to your app of apps:

```jsonnet
apiVersion: 'argoproj.io/v1alpha1',
kind: 'Application',
metadata: { name: 'argocd-with-tanka' },
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
      value: 'environments/argocd-with-tanka',
    }]},
  },
},
```

This manages an argocd namespace and ingress as well as a helm chart to
install argocd. There is also configuration in place to add tanka
support as a plugin.

In a vcluster created before April 2023, after adding this environment
to your control repo, run `kubectl -n argocd get certificates` to make
sure there aren't any certificates. If there are any, `kubectl delete`
them.

Then someone with access to the host cluster needs to run `kubectl get
certificates` there to make sure there's an argocd cert. If there isn't,
the solution is for them to edit the ingress **in the host cluster** to
remove this annotation:

```diff
 annotations:
-  cert-manager.io/cluster-issuer: letsencrypt
```

<details>
<summary>Why does this happen, and why does that fix it?</summary>

In a previous configuration, we were creating certificate objects inside
the vclusters and relying on its syncer to copy them into the host
cluster. This was a good plan in theory but it didn't work in practice,
and certs were expiring, so we opted to prefer simply adding the
clusterissuer annotation and allowing the host cluster to quietly handle
everything.

So if a vcluster is currently managing its argocd certificate
explicitly, using this environment will create a conflict between the
annotation and the explicitly defined certificate.

After removing the certificate object from both the vcluster and the
host cluster (which is entirely safe to do), if the certificate doesn't
automatically reappear, deleting the annotation will cause the following
chain of events:

1.  Vcluster syncer notices the absence of the annotation.
2.  Vcluster syncer re-adds the annotation you deleted.
3.  Cert manager notices the new annotation and the absent certificate.
4.  Cert manager creates the certificate object in the host cluster.

</details>

How to switch to common if you're currently managing your own version
---------------------------------------------------------------------

1.  Disable auto-syncing for argocd.
2.  If you're managing argocd's resources with an Application within
    your app-of-apps, delete it.
3.  Remove all `argocd.argoproj.io/instance` labels from the existing
    resources:

| Namespace |      Resource      |       Name        |
|-----------|--------------------|-------------------|
|           | clusterrolebinding | github-*          |
|           | namespace          | argocd            |
| argocd    | ingress            | argocd            |
| argocd    | configmap          | argocd-tanka-cmp  |
| argocd    | application        | argocd-helm-chart |

Once done, you should be able to add the argocd-with-tanka application
to your app of apps and safely re-enable auto-syncing.
