#!/usr/bin/env bash
#
# check-vbr-ports.sh
#
# Validates TCP connectivity from an RKE2 worker node to Veeam infrastructure,
# per the "Used Ports" tables in KB4626 and the VBR Kasten Integration Guide:
# https://helpcenter.veeam.com/docs/vbr/kasten_integration/used_ports.html
#
# Checked against the VBR server:
#   9419   - VBR REST API port
#   443    - Required from VBR 13 onward: OAuth2 component fetches a
#            certificate via this port to authenticate API access.
#
# Checked against the Repository (may be the same host as VBR, or separate):
#   10006  - vmb api port (datamover -> repository)
#   6162   - veeamtransport (repository management port)
#   2500-3300 - veeamagent data transfer port range
#
# Optional export-type checks (only run if the corresponding *_HOST variable
# is set - unset/empty means skip, so you only check what's actually in use):
#   NFS_HOST  -> 111 (rpcbind), 2049 (nfsd)
#   S3_HOST   -> 443 (HTTPS S3 endpoint)
#   SMB_HOST  -> 445 (SMB over TCP)
#   EXTRA_CHECKS -> comma-separated host:port pairs for anything not covered
#                   above, e.g. "iscsi.lab.home:3260,other.host:1234"
# Set these as environment variables (export NFS_HOST=..., or via the
# DaemonSet's ConfigMap - see DEPLOY.md) rather than script arguments, since
# the number of optional export types can grow without changing the CLI.
#
# The check itself tries, in order: nc, python3, bash's /dev/tcp.
# This matters because /dev/tcp is disabled in some bash builds (notably
# many RHEL/Rocky-family distros compile bash with net redirections off),
# which silently makes every single check report CLOSED regardless of
# actual reachability. Run this first by hand to confirm which case you're in:
#   bash -c 'echo > /dev/tcp/127.0.0.1/22' && echo works || echo broken
#
# Usage: ./check-vbr-ports.sh [VBR_HOST_OR_IP] [REPO_HOST_OR_IP] [timeout_seconds] [parallelism]
# If VBR_HOST_OR_IP / REPO_HOST_OR_IP are omitted, you'll be prompted for them.

set -uo pipefail

VBR_HOST="${1:-}"
REPO_HOST="${2:-}"
TIMEOUT="${3:-1}"
PARALLEL="${4:-50}"

# NFS_HOST / S3_HOST / SMB_HOST / EXTRA_CHECKS come from the environment
# (export before running, or via the DaemonSet ConfigMap). Not treated as
# positional args - keeps the CLI stable as more export types get added.
NFS_HOST="${NFS_HOST:-}"
S3_HOST="${S3_HOST:-}"
SMB_HOST="${SMB_HOST:-}"
EXTRA_CHECKS="${EXTRA_CHECKS:-}"

if [ -z "$VBR_HOST" ]; then
    read -rp "Enter VBR server IP or DNS name: " VBR_HOST
fi

if [ -z "$REPO_HOST" ]; then
    read -rp "Enter Repository IP or DNS name (press Enter if same as VBR server): " REPO_HOST
    REPO_HOST="${REPO_HOST:-$VBR_HOST}"
fi

# Every line printed from here on is prefixed with the node name, so that
# when logs from many pods/nodes are combined (e.g. `kubectl logs -l ...
# --all-containers`), each line is self-identifying without needing to
# cross-reference container IDs back to nodes separately.
# NODE_NAME is injected via the Downward API in the DaemonSet (spec.nodeName);
# falls back to hostname for standalone/SSH runs where that's accurate.
NODE_NAME="${NODE_NAME:-$(hostname)}"
exec > >(sed "s/^/[${NODE_NAME}] /") 2>&1

# Pick the best available method once, up front, and report it so it's obvious
# which check technique produced the results below.
if command -v nc >/dev/null 2>&1; then
    METHOD="nc"
elif command -v python3 >/dev/null 2>&1; then
    METHOD="python3"
else
    METHOD="devtcp"
fi
echo "Using check method: ${METHOD}"

check_port() {
    local host=$1 port=$2 ok=1
    case "$METHOD" in
        nc)
            nc -z -w "$TIMEOUT" "$host" "$port" >/dev/null 2>&1
            ok=$?
            ;;
        python3)
            python3 - "$host" "$port" "$TIMEOUT" >/dev/null 2>&1 <<'EOF'
import socket, sys
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(timeout)
try:
    s.connect((host, port))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
EOF
            ok=$?
            ;;
        devtcp)
            timeout "$TIMEOUT" bash -c "echo > /dev/tcp/${host}/${port}" >/dev/null 2>&1
            ok=$?
            ;;
    esac
    if [ "$ok" -eq 0 ]; then
        echo "OPEN   ${host}:${port}"
    else
        echo "CLOSED ${host}:${port}"
    fi
}
export -f check_port
export TIMEOUT METHOD

echo "=================================================="
echo " VBR/Kasten connectivity check from ${NODE_NAME}"
echo " VBR server:  ${VBR_HOST}"
echo " Repository:  ${REPO_HOST}"
[ -n "$NFS_HOST" ] && echo " NFS export:  ${NFS_HOST}"
[ -n "$S3_HOST" ]  && echo " S3 endpoint: ${S3_HOST}"
[ -n "$SMB_HOST" ] && echo " SMB share:   ${SMB_HOST}"
echo " $(date)"
echo "=================================================="

echo
echo "--- VBR server ports ---"
check_port "$VBR_HOST" 9419
check_port "$VBR_HOST" 443

echo
echo "--- Repository ports ---"
for p in 10006 6162; do
    check_port "$REPO_HOST" "$p"
done

echo
echo "--- VMB agent port range 2500-3300 on Repository (parallel scan, ~1 min) ---"
RESULTS=$(seq 2500 3300 | xargs -P "$PARALLEL" -I{} bash -c "check_port '$REPO_HOST' {}")

OPEN_COUNT=$(echo "$RESULTS" | grep -c '^OPEN')
CLOSED_COUNT=$(echo "$RESULTS" | grep -c '^CLOSED')

echo "Open: ${OPEN_COUNT}   Closed/unreachable: ${CLOSED_COUNT}"

if [ "$CLOSED_COUNT" -gt 0 ]; then
    echo
    echo "Closed/unreachable ports (showing up to 15):"
    echo "$RESULTS" | grep '^CLOSED' | head -15
fi

# --- Optional export-type checks: only run for whichever *_HOST is set ---

if [ -n "$NFS_HOST" ]; then
    echo
    echo "--- NFS export ports (${NFS_HOST}) ---"
    check_port "$NFS_HOST" 111
    check_port "$NFS_HOST" 2049
fi

if [ -n "$S3_HOST" ]; then
    echo
    echo "--- S3 endpoint port (${S3_HOST}) ---"
    check_port "$S3_HOST" 443
fi

if [ -n "$SMB_HOST" ]; then
    echo
    echo "--- SMB share port (${SMB_HOST}) ---"
    check_port "$SMB_HOST" 445
fi

if [ -n "$EXTRA_CHECKS" ]; then
    echo
    echo "--- Extra checks ---"
    IFS=',' read -ra PAIRS <<< "$EXTRA_CHECKS"
    for pair in "${PAIRS[@]}"; do
        ehost="${pair%%:*}"
        eport="${pair##*:}"
        if [ -n "$ehost" ] && [ -n "$eport" ] && [ "$ehost" != "$pair" ]; then
            check_port "$ehost" "$eport"
        else
            echo "Skipping malformed EXTRA_CHECKS entry: '${pair}' (expected host:port)"
        fi
    done
fi

echo
echo "Done. Repeat on each RKE2 worker node against the same VBR server / Repository."
