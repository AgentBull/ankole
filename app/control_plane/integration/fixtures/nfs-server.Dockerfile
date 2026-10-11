# Local kernel NFS server for the Worker entry integration test.
# Setup follows Debian's rpc.nfsd(8), rpc.mountd(8), and exports(5).
ARG WORKER_IMAGE=ankole-agent-computer:integration
FROM ${WORKER_IMAGE}
RUN apt-get update \
  && apt-get install -y --no-install-recommends nfs-kernel-server \
  && rm -rf /var/lib/apt/lists/*
ENV PATH="/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"
ENTRYPOINT ["bash", "-ec"]
# This server starts with no prior leases. Use the minimum recovery grace.
CMD ["mkdir -p /export/agents /proc/fs/nfsd; printf '%s\\n' '/export *(rw,fsid=0,no_subtree_check,no_root_squash,sync)' > /etc/exports; mount -t nfsd nfsd /proc/fs/nfsd; exportfs -ra; rpcbind; rpc.nfsd -G 10 -N 3 4; exec rpc.mountd --foreground --no-nfs-version 3"]
