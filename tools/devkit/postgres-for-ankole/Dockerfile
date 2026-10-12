# syntax=docker/dockerfile:1
FROM rockylinux/rockylinux:9.8

LABEL org.opencontainers.image.title="postgres-for-ankole"
LABEL org.opencontainers.image.description="PostgreSQL 18 image for Ankole Agent with pg_search and pgvector."

COPY ./pgsql.repo /etc/yum.repos.d/

RUN set -eu; \
  for attempt in 1 2 3; do \
    if timeout 240s dnf install -y \
        glibc-langpack-en \
        postgresql18 \
        postgresql18-server \
        postgresql18-libs \
        postgresql18-contrib \
        "https://github.com/paradedb/paradedb/releases/download/v0.25.11/pg_search_18-0.25.11-1PARADEDB.el9.$(rpm --eval '%{_arch}').rpm" \
        pgvector_18* \
        nss_wrapper; then \
      break; \
    fi; \
    if [ "$attempt" -eq 3 ]; then exit 1; fi; \
    sleep $((attempt * 10)); \
  done; \
  dnf clean all; \
  rm -rf /var/cache/dnf

RUN mkdir -p /docker-entrypoint-initdb.d /var/lib/pgsql/18/data \
  && chown -R postgres:postgres /docker-entrypoint-initdb.d /var/lib/pgsql/18/data

ENV PGDATA=/var/lib/pgsql/18/data
ENV PATH=/usr/pgsql-18/bin:$PATH

COPY --chown=postgres:postgres ./docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER postgres

EXPOSE 5432
VOLUME /var/lib/pgsql/18/data

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["postgres", "-c", "shared_preload_libraries=pg_search"]
