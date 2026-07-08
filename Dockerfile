FROM alpine:3.20

RUN apk add --no-cache bash netcat-openbsd python3

COPY check-vbr-ports.sh /usr/local/bin/check-vbr-ports.sh
RUN chmod +x /usr/local/bin/check-vbr-ports.sh

# The DaemonSet passes VBR_HOST / REPO_HOST / TIMEOUT / PARALLEL as args.
# After the check completes, sleep so the pod stays Running (not
# CrashLoopBackOff) and results remain available via `kubectl logs`.
ENTRYPOINT ["/bin/bash", "-c", "/usr/local/bin/check-vbr-ports.sh \"$@\"; echo '--- check complete, pod sleeping for log retrieval ---'; sleep infinity", "--"]
