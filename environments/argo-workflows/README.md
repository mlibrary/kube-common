# Argo Workflows Installation

Each directory under manifests is a versioned, unmodified copy of the manifests
directory from the [Argo Workflows repository](https://github.com/argoproj/argo-workflows/tree/v3.4.11/manifests).

The Argo project uses the Apache License, Version 2.0. Their current, top-level
LICENSE file is included in the manifests directory.

The manifests are accompanied by some Kustomize files ("kustomizations") that
are used to build the combined manifest file in official releases. We reproduce
the source files here so that we can apply Kustomize and specify our minor
adaptations like setting the namespace and adjusting SSL settings.

We use the namespace `workflows`. If you need to use a different one, you can
make further customizations as mentioned below.

## Usage

Kustomize expects to operate on a directory, so each version that we support
has a directory with a `kustomization.yaml` under the `install` directory.

For example, you can render a combined, including all CRDs and resources for
version 3.4.11 with:

```
kustomize build install/v3.4.11
```

We do not recommend running with an image tag of `latest` because it may be
volatile over installations and time. However, there is a symlinked directory
called `latest` that will build the newest vendored version.

## Installing with Argo CD

Argo CD has built-in support for Kustomize, so an Application that refers to
one of the versions under `install` will automatically build and apply the
manifests. The "type" of application is detected by the presence of the
`kustomization.yaml`, so there are no additional parameters needed. However,
there are Argo CD-specific [options](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/)
that may help avoid vendoring or using this repository as a remote source
if you need to make minor adjustments. For example, you could specify a
custom namespace at the Application without building a Kustomization file.

Here is a complete example definition of an Argo CD Application in Jsonnet,
which would likely be placed in your "app of apps":

```jsonnet
  argo_workflows: {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: { name: 'argo-workflows' },
    spec: {
      project: 'default',
      destination: { server: 'https://kubernetes.default.svc' },
      syncPolicy: { automated: { prune: true, selfHeal: true } },
      source: {
        repoURL: 'https://github.com/mlibrary/kube-common',
        targetRevision: 'argo-workflows',
        path: 'environments/argo-workflows/install/v3.4.11',
      },
    },
  }
```

The equivalent Application could be defined directly in YAML or any other way
that Argo CD would pick up.
