#!/bin/bash
set -e
shopt -s extglob
source ${PG_APP_HOME}/env-defaults.sh

PG_CONF=${PG_DATADIR}/postgresql.conf
PG_HBA_CONF=${PG_DATADIR}/pg_hba.conf
PG_IDENT_CONF=${PG_DATADIR}/pg_ident.conf
PG_RECOVERY_CONF=${PG_DATADIR}/recovery.conf

## Execute command as PG_USER
exec_as_postgres() {
  if [[ $(whoami) == ${PG_USER} ]]; then
    $@
  else
    sudo -HEu ${PG_USER} "$@"
  fi
}

map_uidgid() {
  USERMAP_ORIG_UID=$(id -u ${PG_USER})
  USERMAP_ORIG_GID=$(id -g ${PG_USER})
  USERMAP_GID=${USERMAP_GID:-${USERMAP_UID:-$USERMAP_ORIG_GID}}
  USERMAP_UID=${USERMAP_UID:-$USERMAP_ORIG_UID}
  if [[ ${USERMAP_UID} != ${USERMAP_ORIG_UID} ]] || [[ ${USERMAP_GID} != ${USERMAP_ORIG_GID} ]]; then
    echo "Mapping UID and GID for ${PG_USER}:${PG_USER} to $USERMAP_UID:$USERMAP_GID"
    groupmod -o -g ${USERMAP_GID} ${PG_USER}
    sed -i -e "s|:${USERMAP_ORIG_UID}:${USERMAP_GID}:|:${USERMAP_UID}:${USERMAP_GID}:|" /etc/passwd
    find ${PG_HOME} -path ${PG_HOME}/\* -prune -o -print0 | xargs -0 chown -h ${PG_USER}:
  fi
}

create_datadir() {
  echo "Initializing homedir..."
  mkdir -p ${PG_HOME}
  chmod -R 755 ${PG_HOME}
  chown -R ${PG_USER}: ${PG_HOME}
  
  echo "Initializing datadir..."
  mkdir -p ${PG_DATADIR}
  chmod 750 ${PG_DATADIR}
  find ${PG_DATADIR} -type d -print0 | xargs -0 -I {} chmod 0700 {}
  find ${PG_DATADIR} -type f -print0 | xargs -0 -I {} chmod 0600 {}
  chown -R ${PG_USER}: ${PG_DATADIR}
}

create_certdir() {
  echo "Initializing certdir..."
  mkdir -p ${PG_CERTDIR}
  chmod -R 0750 ${PG_CERTDIR}
  [[ -f ${PG_CERTDIR}/server.crt ]] && chmod 0644 ${PG_CERTDIR}/server.crt
  [[ -f ${PG_CERTDIR}/server.key ]] && chmod 0640 ${PG_CERTDIR}/server.key
  chown -R root: ${PG_CERTDIR}
}

create_logdir() {
  echo "Initializing logdir..."
  mkdir -p ${PG_LOGDIR}
  chmod -R 1775 ${PG_LOGDIR}
  chown -R root: ${PG_LOGDIR}
}

create_rundir() {
  echo "Initializing rundir..."
  mkdir -p ${PG_RUNDIR} ${PG_RUNDIR}/${PG_VERSION}-main.pg_stat_tmp
  chmod -R 0750 ${PG_RUNDIR}
  chmod g+s ${PG_RUNDIR}
  chown -R ${PG_USER}: ${PG_RUNDIR}
}

set_postgresql_param() {
  local key=${1}
  local value=${2}
  local verbosity=${3:-verbose}

  if [[ -n ${value} ]]; then
    local current=$(exec_as_postgres sed -n -e "s/^\(${key} = '\)\([^ ']*\)\(.*\)$/\2/p" ${PG_CONF})
    if [[ "${current}" != "${value}" ]]; then
      if [[ ${verbosity} == verbose ]]; then
        echo "‣ Setting postgresql.conf parameter: ${key} = '${value}'"
      fi
      value="$(echo "${value}" | sed 's|[&]|\\&|g')"
      exec_as_postgres sed -i "s|^[#]*[ ]*${key} = .*|${key} = '${value}'|" ${PG_CONF}
    fi
  fi
}

set_recovery_param() {
  local key=${1}
  local value=${2}
  local hide=${3}
  if [[ -n ${value} ]]; then
    local current=$(exec_as_postgres sed -n -e "s/^\(.*\)\(${key}=\)\([^ ']*\)\(.*\)$/\3/p" ${PG_RECOVERY_CONF})
    if [[ "${current}" != "${value}" ]]; then
      case ${hide} in
        true)  echo "‣ Setting primary_conninfo parameter: ${key}" ;;
        *) echo "‣ Setting primary_conninfo parameter: ${key} = '${value}'" ;;
      esac
      exec_as_postgres sed -i "s|${key}=[^ ']*|${key}=${value}|" ${PG_RECOVERY_CONF}
    fi
  fi
}

set_hba_param() {
  local value=${1}
  if ! grep -q "$(sed "s| | \\\+|g" <<< ${value})" ${PG_HBA_CONF}; then
    echo "${value}" >> ${PG_HBA_CONF}
  fi
}

configure_ssl() {
  ## NOT SURE IF THIS IS A GOOD ALTERNATIVE TO ENABLE SSL SUPPORT BY DEFAULT ##
  ## BECAUSE USERS WHO PULL A PREBUILT IMAGE WILL HAVE THE SAME CERTIFICATES ##
  # if [[ ! -f ${PG_CERTDIR}/server.crt && ! -f ${PG_CERTDIR}/server.key ]]; then
  #   if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem && -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
  #     ln -sf /etc/ssl/certs/ssl-cert-snakeoil.pem ${PG_CERTDIR}/server.crt
  #     ln -sf /etc/ssl/private/ssl-cert-snakeoil.key ${PG_CERTDIR}/server.key
  #   fi
  # fi

  if [[ -f ${PG_CERTDIR}/server.crt && -f ${PG_CERTDIR}/server.key ]]; then
    PG_SSL=${PG_SSL:-on}
    set_postgresql_param "ssl_cert_file" "${PG_CERTDIR}/server.crt"
    set_postgresql_param "ssl_key_file" "${PG_CERTDIR}/server.key"
  fi
  PG_SSL=${PG_SSL:-off}
  set_postgresql_param "ssl" "${PG_SSL}"
}

configure_hot_standby() {
  case ${REPLICATION_MODE} in
    slave|snapshot|backup) ;;
    *)
      echo "Configuring hot standby..."
      set_postgresql_param "wal_level" "hot_standby"
      set_postgresql_param "max_wal_senders" "16"
      set_postgresql_param "checkpoint_segments" "8"
      set_postgresql_param "wal_keep_segments" "32"
      set_postgresql_param "hot_standby" "on"
      ;;
  esac
}

initialize_database() {
  if [[ ! -f ${PG_DATADIR}/PG_VERSION ]]; then
    case ${REPLICATION_MODE} in
      slave|snapshot|backup)
        if [[ -z $REPLICATION_HOST ]]; then
          echo "ERROR! Cannot continue without the REPLICATION_HOST. Exiting..."
          exit 1
        fi

        if [[ -z $REPLICATION_USER ]]; then
          echo "ERROR! Cannot continue without the REPLICATION_USER. Exiting..."
          exit 1
        fi

        if [[ -z $REPLICATION_PASS ]]; then
          echo "ERROR! Cannot continue without the REPLICATION_PASS. Exiting..."
          exit 1
        fi

        echo -n "Waiting for $REPLICATION_HOST to accept connections (60s timeout)"
        timeout=60
        while ! ${PG_BINDIR}/pg_isready -h $REPLICATION_HOST -p $REPLICATION_PORT -t 1 >/dev/null 2>&1
        do
          timeout=$(expr $timeout - 1)
          if [[ $timeout -eq 0 ]]; then
            echo "Timeout! Exiting..."
            exit 1
          fi
          echo -n "."
          sleep 1
        done
        echo

        case ${REPLICATION_MODE} in
          slave)
            echo "Replicating initial data from $REPLICATION_HOST..."
            exec_as_postgres PGPASSWORD=$REPLICATION_PASS ${PG_BINDIR}/pg_basebackup -D ${PG_DATADIR} \
              -h ${REPLICATION_HOST} -p ${REPLICATION_PORT} -U ${REPLICATION_USER} -X stream -w >/dev/null
            ;;
          snapshot)
            echo "Generating a snapshot data on $REPLICATION_HOST..."
            exec_as_postgres PGPASSWORD=$REPLICATION_PASS ${PG_BINDIR}/pg_basebackup -D ${PG_DATADIR} \
              -h ${REPLICATION_HOST} -p ${REPLICATION_PORT} -U ${REPLICATION_USER} -X fetch -w >/dev/null
            ;;
          backup)
            echo "Backing up data on $REPLICATION_HOST..."
            exec_as_postgres PGPASSWORD=$REPLICATION_PASS ${PG_BINDIR}/pg_basebackup -D ${PG_DATADIR} \
              -h ${REPLICATION_HOST} -p ${REPLICATION_PORT} -U ${REPLICATION_USER} -X fetch -w >/dev/null
            exit 0
            ;;
        esac
        ;;
      *)
        echo "Initializing database..."
        PG_OLD_VERSION=$(find ${PG_HOME}/+([0-9])?(.[0-9])/main -maxdepth 1 -name PG_VERSION 2>/dev/null | grep -v $PG_VERSION | sort -r | head -n1 | cut -d'/' -f5)
        if [[ -n ${PG_OLD_VERSION} ]]; then
          echo "‣ Migrating PostgreSQL ${PG_OLD_VERSION} data to ${PG_VERSION}..."

          # protect the existing data from being altered by apt
          chmod -R 750 ${PG_HOME}/${PG_OLD_VERSION}
          mv ${PG_HOME}/${PG_OLD_VERSION} ${PG_HOME}/${PG_OLD_VERSION}.migrating

          echo "‣ Installing PostgreSQL ${PG_OLD_VERSION}..."
          if ! ( apt update &&  DEBIAN_FRONTEND=noninteractive apt install -y postgresql-${PG_OLD_VERSION} postgresql-client-${PG_OLD_VERSION} ) >/dev/null; then
            echo "ERROR! Failed to install PostgreSQL ${PG_OLD_VERSION}. Exiting..."
            # first move the old data back
            rm -rf ${PG_HOME}/${PG_OLD_VERSION}
            mv ${PG_HOME}/${PG_OLD_VERSION}.migrating ${PG_HOME}/${PG_OLD_VERSION}
            exit 1
          fi
          rm -rf /var/lib/apt/lists/*

          # we're ready to migrate, move back the old data and remove the trap
          rm -rf ${PG_HOME}/${PG_OLD_VERSION}
          mv ${PG_HOME}/${PG_OLD_VERSION}.migrating ${PG_HOME}/${PG_OLD_VERSION}
        fi

        if [[ -n $PG_PASSWORD ]]; then
          echo "${PG_PASSWORD}" > /tmp/pwfile
        fi

        exec_as_postgres ${PG_BINDIR}/initdb --pgdata=${PG_DATADIR} \
          --username=${PG_USER} --encoding=unicode --auth=trust ${PG_PASSWORD:+--pwfile=/tmp/pwfile} >/dev/null

        if [[ -n ${PG_OLD_VERSION} ]]; then
          PG_OLD_BINDIR=/usr/lib/postgresql/${PG_OLD_VERSION}/bin
          PG_OLD_DATADIR=${PG_HOME}/${PG_OLD_VERSION}/main
          PG_OLD_CONF=${PG_OLD_DATADIR}/postgresql.conf
          PG_OLD_HBA_CONF=${PG_OLD_DATADIR}/pg_hba.conf
          PG_OLD_IDENT_CONF=${PG_OLD_DATADIR}/pg_ident.conf

          echo -n "‣ Migration in progress. Please be patient..."
          exec_as_postgres ${PG_BINDIR}/pg_upgrade \
            -b ${PG_OLD_BINDIR} -B ${PG_BINDIR} \
            -d ${PG_OLD_DATADIR} -D ${PG_DATADIR} \
            -o "-c config_file=${PG_OLD_CONF} --hba_file=${PG_OLD_HBA_CONF} --ident_file=${PG_OLD_IDENT_CONF}" \
            -O "-c config_file=${PG_CONF} --hba_file=${PG_HBA_CONF} --ident_file=${PG_IDENT_CONF}"
          echo
        fi
        ;;
    esac

    configure_hot_standby

    # Change DSM from `posix' to `sysv' if we are inside an lx-brand container
    if [[ $(uname -v) == "BrandZ virtual linux" ]]; then
      set_postgresql_param "dynamic_shared_memory_type" "sysv"
    fi
  fi

  # configure path to data_directory
  set_postgresql_param "data_directory" "${PG_DATADIR}"

  # configure logging
  set_postgresql_param "log_directory" "${PG_LOGDIR}"
  set_postgresql_param "log_filename" "postgresql-${PG_VERSION}-main.log"

  # trust connections from local network
  if [[ ${PG_TRUST_LOCALNET} == true ]]; then
    echo "Trusting connections from the local network..."
    set_hba_param "host all all samenet trust"
  fi

  # allow remote connections to postgresql database
  set_hba_param "host all all 0.0.0.0/0 md5"
}

set_resolvconf_perms() {
  echo "Setting resolv.conf ACLs..."
  setfacl -m user:${PG_USER}:r /etc/resolv.conf || true
}

configure_recovery() {
  if [[ ${REPLICATION_MODE} == slave ]]; then
    echo "Configuring recovery..."
    if [[ ! -f ${PG_RECOVERY_CONF} ]]; then
      # initialize recovery.conf on the firstrun (slave only)
      exec_as_postgres touch ${PG_RECOVERY_CONF}
      ( echo "standby_mode = 'on'";
        echo "primary_conninfo = 'host=${REPLICATION_HOST} port=${REPLICATION_PORT} user=${REPLICATION_USER} password=${REPLICATION_PASS} sslmode=${REPLICATION_SSLMODE}'";
      ) > ${PG_RECOVERY_CONF}
    else
      set_recovery_param "host"      "${REPLICATION_HOST}"
      set_recovery_param "port"      "${REPLICATION_PORT}"
      set_recovery_param "user"      "${REPLICATION_USER}"
      set_recovery_param "password"  "${REPLICATION_PASS}"    "true"
      set_recovery_param "sslmode"   "${REPLICATION_SSLMODE}"
    fi
  else
    # recovery.conf can only exist on a slave node, its existence otherwise causes problems
    rm -rf ${PG_RECOVERY_CONF}
  fi
}

create_user() {
  if [[ -n ${DB_USER} ]]; then
    case $REPLICATION_MODE in
      slave|snapshot|backup)
        echo "INFO! Database user cannot be created on a $REPLICATION_MODE node. Skipping..."
        ;;
      *)
        if [[ -z ${DB_PASS} ]]; then
          echo "ERROR! Please specify a password for DB_USER in DB_PASS. Exiting..."
          exit 1
        fi
        echo "Creating database user: ${DB_USER}"
        if [[ -z $(psql -U ${PG_USER} -Atc "SELECT 1 FROM pg_catalog.pg_user WHERE usename = '${DB_USER}'";) ]]; then
          psql -U ${PG_USER} -c "CREATE ROLE \"${DB_USER}\" with LOGIN CREATEDB PASSWORD '${DB_PASS}';" >/dev/null
        fi
        ;;
    esac
  fi
}

load_extensions() {
  local database=${1?missing argument}

  if [[ ${DB_UNACCENT} == true ]]; then
    echo
    echo "WARNING: "
    echo "  The DB_UNACCENT option will be deprecated in favour of DB_EXTENSION soon."
    echo "  Please migrate to using DB_EXTENSION"
    echo
    echo "‣ Loading unaccent extension..."
    psql -U ${PG_USER} -d ${database} -c "CREATE EXTENSION IF NOT EXISTS unaccent;" >/dev/null 2>&1
  fi

  for extension in $(awk -F',' '{for (i = 1 ; i <= NF ; i++) print $i}' <<< "${DB_EXTENSION}"); do
    echo "‣ Loading ${extension} extension..."
    psql -U ${PG_USER} -d ${database} -c "CREATE EXTENSION IF NOT EXISTS ${extension};" >/dev/null 2>&1
  done
  
  # Leave this verbose
  if psql -U ${PG_USER} -d ${database} -c "SELECT PostGIS_version();"; then
    # Update PostGIS to current version
    psql -U ${PG_USER} -d ${database} -c "SELECT postgis_extensions_upgrade();"
  fi
}

create_database() {
  if [[ -n ${DB_NAME} ]]; then
    case $REPLICATION_MODE in
      slave|snapshot|backup)
        echo "INFO! Database cannot be created on a $REPLICATION_MODE node. Skipping..."
        ;;
      *)
        for database in $(awk -F',' '{for (i = 1 ; i <= NF ; i++) print $i}' <<< "${DB_NAME}"); do
          echo "Creating database: ${database}..."
          if [[ -z $(psql -U ${PG_USER} -Atc "SELECT 1 FROM pg_catalog.pg_database WHERE datname = '${database}'";) ]]; then
            psql -U ${PG_USER} -c "CREATE DATABASE \"${database}\" WITH TEMPLATE = \"${DB_TEMPLATE}\";" >/dev/null
          fi

          load_extensions ${database}

          if [[ -n ${DB_USER} ]]; then
            echo "‣ Granting access to ${DB_USER} user..."
            psql -U ${PG_USER} -c "GRANT ALL PRIVILEGES ON DATABASE \"${database}\" TO \"${DB_USER}\";" >/dev/null
            # Needed after PostgreSQL 15 release
            psql -U ${PG_USER} -d ${database} -c "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";" >/dev/null
          fi
        done
        ;;
    esac
  fi
}

create_replication_user() {
  if [[ -n ${REPLICATION_USER} ]]; then
    case $REPLICATION_MODE in
      slave|snapshot|backup) ;; # replication user can only be created on the master
      *)
        if [[ -z ${REPLICATION_PASS} ]]; then
          echo "ERROR! Please specify a password for REPLICATION_USER in REPLICATION_PASS. Exiting..."
          exit 1
        fi

        echo "Creating replication user: ${REPLICATION_USER}"
        if [[ -z $(psql -U ${PG_USER} -Atc "SELECT 1 FROM pg_catalog.pg_user WHERE usename = '${REPLICATION_USER}'";) ]]; then
          psql -U ${PG_USER} -c "CREATE ROLE \"${REPLICATION_USER}\" WITH REPLICATION LOGIN ENCRYPTED PASSWORD '${REPLICATION_PASS}';" >/dev/null
        fi

        set_hba_param "host replication ${REPLICATION_USER} 0.0.0.0/0 md5"
        ;;
    esac
  fi
}

configure_postgresql() {
  initialize_database
  configure_recovery
  configure_ssl

  # start postgres server internally for the creation of users and databases
  rm -rf ${PG_DATADIR}/postmaster.pid
  set_postgresql_param "listen_addresses" "127.0.0.1" quiet
  exec_as_postgres ${PG_BINDIR}/pg_ctl -D ${PG_DATADIR} -w start >/dev/null

  create_user
  create_database
  create_replication_user

  # stop the postgres server
  exec_as_postgres ${PG_BINDIR}/pg_ctl -D ${PG_DATADIR} -w stop >/dev/null

  # listen on all interfaces
  set_postgresql_param "listen_addresses" "*" quiet
}
