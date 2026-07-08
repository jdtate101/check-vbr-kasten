# Deploying check-vbr-ports as a DaemonSet

Runs the port check automatically on every RKE2 worker node in the cluster, in one shot, instead of SSH-ing to each node manually.

## Files

- `Dockerfile` — Alpine-based image containing the script and its dependencies (`nc`, `python3`, `bash`)
- `check-vbr-ports.sh` — the check script itself (must be in the same directory as the Dockerfile when building)
- `vbr-port-check-daemonset.yaml` — DaemonSet manifest that runs the image on every worker node

## 1. Build and push the image

```bash
docker build -t <DOCKERHUB_USERNAME>/vbr-port-check:latest .
docker login
docker push <DOCKERHUB_USERNAME>/vbr-port-check:latest
```

Replace `<DOCKERHUB_USERNAME>` with your actual Docker Hub username or org.

## 2. Edit the manifest

Open `vbr-port-check-daemonset.yaml` and update:
- `image:` — match the tag you just pushed
- `args:` — set the actual VBR server IP/DNS, Repository IP/DNS, timeout, and parallelism for the target environment

## 3. Deploy

```bash
kubectl apply -f vbr-port-check-daemonset.yaml
```

Give it a minute for pods to schedule and the checks to complete (the port-range scan alone takes roughly a minute per node).

## 4. Collect results

List the pods to confirm one landed on each worker node:
```bash
kubectl get pods -l app=vbr-port-check -o wide
```

Pull logs from all of them at once:
```bash
kubectl logs -l app=vbr-port-check --all-containers --prefix=true
```

Or one node at a time:
```bash
kubectl logs <pod-name>
```

Pods stay `Running` after the check completes (they sleep rather than exit), so logs remain available until you clean up — no need to rush collecting them.

## 5. Clean up

```bash
kubectl delete -f vbr-port-check-daemonset.yaml
```

## Reading results

Same as running the script directly:
- **9419, 443, 10006, 6162 should show OPEN** on every node. Any CLOSED here points to a firewall/ACL issue specific to that node's path. Note: 443 is only required from VBR 13 onward (OAuth2 certificate retrieval).
- **2500–3300 will show CLOSED at idle — this is expected**, not a fault. That range only opens dynamically during an active backup/restore job.

## Notes

- No tolerations are set in the manifest, so on a standard RKE2 cluster the DaemonSet will only schedule on worker nodes (control-plane nodes carry a `NoSchedule` taint by default). If the customer's cluster has combined master+worker nodes, add a `nodeSelector` to the manifest instead.
- `hostNetwork: true` is required — it's what makes the check reflect the real worker node network path rather than the pod/CNI overlay network.
