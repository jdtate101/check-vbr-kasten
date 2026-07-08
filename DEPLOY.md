# Deploying check-vbr-ports as a DaemonSet

Runs the port check automatically on every RKE2 worker node in the cluster, in one shot, instead of SSH-ing to each node manually.

## Files

- `Dockerfile` — Alpine-based image containing the script and its dependencies (`nc`, `python3`, `bash`)
- `check-vbr-ports.sh` — the check script itself (must be in the same directory as the Dockerfile when building)
- `vbr-port-check-configmap.yaml` — export-type toggles (NFS/S3/SMB/extra checks)
- `vbr-port-check-daemonset.yaml` — DaemonSet manifest that runs the image on every worker node

## 1. Build and push the image

```bash
docker build -t <DOCKERHUB_USERNAME>/vbr-port-check:latest .
docker login
docker push <DOCKERHUB_USERNAME>/vbr-port-check:latest
```

Replace `<DOCKERHUB_USERNAME>` with your actual Docker Hub username or org.

## 2. Edit the manifests

In `vbr-port-check-configmap.yaml`, fill in whichever export types this environment actually uses (`NFS_HOST`, `S3_HOST`, `SMB_HOST`, `EXTRA_CHECKS`) — leave the rest blank to skip those checks entirely.

In `vbr-port-check-daemonset.yaml`, update:
- `image:` — match the tag you just pushed
- `args:` — set the actual VBR server IP/DNS, Repository IP/DNS, timeout, and parallelism for the target environment

`NODE_NAME` doesn't need editing — it's wired to the Downward API (`spec.nodeName`) so each pod picks up its own node's real name automatically.

## 3. Deploy

Apply the ConfigMap first — the DaemonSet references it via `envFrom`, so it needs to exist before (or at worst, alongside) the pods start:
```bash
kubectl apply -f vbr-port-check-configmap.yaml
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
kubectl logs -l app=vbr-port-check --all-containers --prefix=true --tail=-1
```

`--tail=-1` matters here — `kubectl logs` with a label selector (`-l`) defaults to showing only the last 10 lines per container, which will silently cut off the earlier port checks and only show the tail end of the range scan. `--tail=-1` disables that limit and shows the full log.

Each line is also prefixed with the actual node name by the script itself (e.g. `[rke2-worker-03] OPEN 192.168.1.153:9419`), not just the pod name `--prefix` adds — pod names for a DaemonSet are random suffixes and don't identify which node produced a given line on their own, so this is what makes combined output from every node actually readable.

Or one node at a time:
```bash
kubectl logs <pod-name>
```

Pods stay `Running` after the check completes (they sleep rather than exit), so logs remain available until you clean up — no need to rush collecting them.

## 5. Clean up

```bash
kubectl delete -f vbr-port-check-daemonset.yaml
kubectl delete -f vbr-port-check-configmap.yaml
```

## Reading results

Same as running the script directly:
- **9419, 443, 10006, 6162 should show OPEN** on every node. Any CLOSED here points to a firewall/ACL issue specific to that node's path. Note: 443 is only required from VBR 13 onward (OAuth2 certificate retrieval).
- **2500–3300 will show CLOSED at idle — this is expected**, not a fault. That range only opens dynamically during an active backup/restore job.
- **NFS/S3/SMB/extra sections only appear if the corresponding ConfigMap value was set.** An empty `NFS_HOST` etc. means that section is silently skipped, not a failed check — check the ConfigMap if a section you expected is missing from the output.

## Notes

- No tolerations are set in the manifest, so on a standard RKE2 cluster the DaemonSet will only schedule on worker nodes (control-plane nodes carry a `NoSchedule` taint by default). If the customer's cluster has combined master+worker nodes, add a `nodeSelector` to the manifest instead.
- `hostNetwork: true` is required — it's what makes the check reflect the real worker node network path rather than the pod/CNI overlay network.
