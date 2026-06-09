# syntax=docker/dockerfile:1
FROM rockylinux/rockylinux:9.5

LABEL org.opencontainers.image.title="postgres-for-bullx"
LABEL org.opencontainers.image.description="PostgreSQL 18 image for BullX Agent with pg_search and pgvector."

COPY ./pgsql.repo /etc/yum.repos.d/

RUN dnf install -y \
    postgresql18 \
    postgresql18-server \
    postgresql18-libs \
    postgresql18-contrib \
    postgresql18-llvmjit \
    pg_search_18* \
    pgvector_18* \
    nss_wrapper \
  && dnf clean all \
  && rm -rf /var/cache/dnf

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
CMD ["postgres"]
