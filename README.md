# check-vbr-ports.sh

Checks TCP connectivity from an RKE2 worker node to a Veeam Backup & Replication (VBR) server and repository, for validating network prerequisites ahead of Veeam Kasten integration.

Reference: [VBR Kasten Integration Guide – Used Ports](https://helpcenter.veeam.com/docs/vbr/kasten_integration/used_ports.html)

## What it checks

| Target | Port(s) | Purpose |
|---|---|---|
| VBR server | 9419 | VBR REST API |
| VBR server | 443 | VBR 13+: OAuth2 component fetches a certificate via this port to authenticate API access |
| Repository | 10006 | vmb api port (datamover → repository) |
| Repository | 6162 | veeamtransport (repository management) |
| Repository | 2500–3300 | veeamagent data transfer (dynamic, job-only) |

The VBR server and Repository can be the same host or different hosts — you're prompted for both when running the script (or pass them as arguments).

## Requirements

None to install. The script auto-detects the best available tool on the node, in this order: `nc` → `python3` → bash's built-in `/dev/tcp`. Almost every RKE2 node will have at least one of these already.

## Usage

Interactive (prompts for both hosts):
```bash
chmod +x check-vbr-ports.sh
./check-vbr-ports.sh
```

Non-interactive (useful when running the same check across multiple nodes):
```bash
./check-vbr-ports.sh <VBR_HOST_OR_IP> <REPO_HOST_OR_IP> [timeout_seconds] [parallelism]
```

Example:
```bash
./check-vbr-ports.sh 192.168.1.153 192.168.1.153 1 50
```

If VBR and Repository are the same server, just press Enter at the Repository prompt (or pass the same value twice).

## Reading the results

- `OPEN` / `CLOSED` is printed per port.
- **9419, 443, 10006, and 6162 should all show OPEN** if the network path is clear. If any show CLOSED, check for firewall/ACL/NSG rules between the worker node subnet and the VBR host on that specific port. Note: 443 is only required from VBR 13 onward (OAuth2 certificate retrieval) — on earlier VBR versions it's not applicable.
- **The 2500–3300 range will show CLOSED at idle — this is expected, not a fault.** Veeam only opens ports in this range dynamically, for the duration of an active backup or restore job. An all-CLOSED result here with no job running is the correct baseline, not a network problem. To validate this range specifically, re-run the scan while a Kasten backup or restore is actively in progress against that repository — you should then see a handful of ports in the range flip to OPEN.

## Files in this repo

- `check-vbr-ports.sh` — the script itself
- `Dockerfile` — container image build for running the check as a Kubernetes DaemonSet
- `vbr-port-check-daemonset.yaml` — DaemonSet manifest to run the check on every worker node at once
- `DEPLOY.md` — build/push/deploy/collect instructions for the containerized version

## Running at scale

Running this by hand via SSH on every worker node doesn't scale well past a handful of nodes. For clusters with more than a few workers, use the containerized version instead — it runs the same script automatically across every worker node via a DaemonSet, with results collected through `kubectl logs`. See **[DEPLOY.md](./DEPLOY.md)** for the full build → push → deploy → collect → cleanup process.

## Notes

- Run this on each worker node individually (via SSH) — connectivity can differ node to node depending on subnet, NIC, or local firewall rules. Alternatively, see **Running at scale** above for the DaemonSet approach.
- The port range scan takes roughly a minute due to the number of ports checked; adjust `parallelism` (4th argument) if it needs to run faster or lighter, or `timeout_seconds` (3rd argument) if the network path has higher latency.
