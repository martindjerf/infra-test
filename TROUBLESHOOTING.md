# Troubleshooting

## ArgoCD application controller cannot reach the Kubernetes API

### Symptom

ArgoCD application controller logs show:

```
Get "https://10.43.0.1:443/version?timeout=32s": dial tcp 10.43.0.1:443: connect: connection refused
```

Sync status stays `Unknown`. Health status may show `Healthy` (ArgoCD can see live resources but cannot compare against Git).

### Root cause

Civo managed k3s runs the control plane externally. The `kubernetes` ClusterIP service (`10.43.0.1:443`) is a virtual IP that kube-proxy DNAT's to the actual control plane endpoint — a public IP on port 6443.

Check the actual endpoint:

```
kubectl get endpoints kubernetes -n default
```

The Civo CNI evaluates network policies **after DNAT**. This means a policy allowing `10.43.0.1/32:443` never matches — by the time the CNI evaluates the packet, the destination is already the real endpoint IP on port 6443. The packet hits `default-deny-all` and is dropped.

### How we found it

1. Checked application controller logs — confirmed the exact IP and port it was failing to reach.
2. Ran a nettest pod pinned to the same node to rule out node-level issues:
   ```
   kubectl run -n argocd --rm -it nettest --image=busybox --restart=Never \
     --overrides='{"spec":{"nodeName":"<node-name>"}}' -- nc -zv 10.43.0.1 443
   ```
3. Tested from inside the application controller container directly:
   ```
   kubectl exec -n argocd statefulset/argocd-application-controller -- \
     bash -c "echo > /dev/tcp/10.43.0.1/443 && echo connected || echo failed"
   ```
   This confirmed connectivity failed specifically from that container, not a node issue.
4. Checked the actual API server endpoint behind the ClusterIP:
   ```
   kubectl get endpoints kubernetes -n default
   ```
   Revealed the real destination: `74.220.23.49:6443`.

### Fix

Update the `allow-k8s-api-egress` network policy in the `argocd` namespace to target the actual control plane IP and port instead of the ClusterIP:

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 74.220.23.49/32
    ports:
      - protocol: TCP
        port: 6443
```

After applying, restart the application controller:

```
kubectl rollout restart statefulset/argocd-application-controller -n argocd
```

### Note on other namespaces

If you apply the same default-deny-all pattern to other namespaces and their workloads need to talk to the Kubernetes API, use the same approach — target the actual endpoint IP on port 6443, not the ClusterIP on port 443.

Get the current endpoint IP any time with:

```
kubectl get endpoints kubernetes -n default
```

Note that this IP is controlled by Civo and could change if the cluster is recreated.
