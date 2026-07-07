#!/usr/bin/env bash
#
# check-vbr-ports.sh
#
# Validates TCP connectivity from an RKE2 worker node to the VBR server,
# per the "Used Ports" tables in KB4626 and the VBR Kasten Integration Guide:
# https://helpcenter.veeam.com/docs/vbr/kasten_integration/used_ports.html
#
# Checked against the VBR server:
#   9419   - VBR REST API port
#
# Checked against the Repository (may be the same host as VBR, or separate):
#   10006  - vmb api port (datamover -> repository)
#   6162   - veeamtransport (repository management port)
#   2500-3300 - veeamagent data transfer port range
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

if [ -z "$VBR_HOST" ]; then
    read -rp "Enter VBR server IP or DNS name: " VBR_HOST
fi

if [ -z "$REPO_HOST" ]; then
    read -rp "Enter Repository IP or DNS name (press Enter if same as VBR server): " REPO_HOST
    REPO_HOST="${REPO_HOST:-$VBR_HOST}"
fi

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
echo " VBR/Kasten connectivity check from $(hostname)"
echo " VBR server:  ${VBR_HOST}"
echo " Repository:  ${REPO_HOST}"
echo " $(date)"
echo "=================================================="

echo
echo "--- VBR server port ---"
check_port "$VBR_HOST" 9419

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

echo
echo "Done. Repeat on each RKE2 worker node against the same VBR server / Repository."
