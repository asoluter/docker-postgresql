FROM ubuntu:noble AS add-apt-repositories

RUN apt update \
 && DEBIAN_FRONTEND=noninteractive apt install -y curl ca-certificates gnupg lsb-release \
 && curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg >/dev/null \
 && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

FROM ubuntu:noble 

LABEL maintainer="asoluter@gmail.com"

ENV PG_APP_HOME="/etc/docker-postgresql" \
    PG_VERSION=17 \
    PG_USER=postgres \
    PG_HOME=/var/lib/postgresql \
    PG_RUNDIR=/run/postgresql \
    PG_LOGDIR=/var/log/postgresql \
    PG_CERTDIR=/etc/postgresql/certs

ENV PG_BINDIR=/usr/lib/postgresql/${PG_VERSION}/bin \
    PG_DATADIR=${PG_HOME}/${PG_VERSION}/main

COPY --from=add-apt-repositories /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg

COPY --from=add-apt-repositories /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.list

RUN apt update \
 && DEBIAN_FRONTEND=noninteractive apt upgrade -y \
 && DEBIAN_FRONTEND=noninteractive apt autoremove -y \
 && DEBIAN_FRONTEND=noninteractive apt install -y acl sudo locales \
        postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} postgresql-contrib-${PG_VERSION} \
 && update-locale LANG=C.UTF-8 LC_MESSAGES=POSIX \
 && locale-gen en_US.UTF-8 \
 && DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales \
 && ln -sf ${PG_DATADIR}/postgresql.conf /etc/postgresql/${PG_VERSION}/main/postgresql.conf \
 && ln -sf ${PG_DATADIR}/pg_hba.conf /etc/postgresql/${PG_VERSION}/main/pg_hba.conf \
 && ln -sf ${PG_DATADIR}/pg_ident.conf /etc/postgresql/${PG_VERSION}/main/pg_ident.conf \
 && rm -rf ${PG_HOME} \
 && rm -rf /var/lib/apt/lists/*

COPY runtime/ ${PG_APP_HOME}/

COPY entrypoint.sh /sbin/entrypoint.sh

RUN chmod 755 /sbin/entrypoint.sh

EXPOSE 5432/tcp

WORKDIR ${PG_HOME}

ENTRYPOINT ["/sbin/entrypoint.sh"]
