#!/bin/bash

function pwgen {
  tr -cd '[:alnum:]' < /dev/urandom | fold -w$1 | head -n1
}

function check_eula {
  if [[ -z "$XL_LICENSE" && -z "$XL_NO_UNREGISTERED_LICENSE" && ! -f "${APP_HOME}/conf/deployit-license.lic" && "$XL_LICENSE_KIND" == "byol" ]]; then
      if [[  "$ACCEPT_EULA" != "Y" && "$ACCEPT_EULA" != "y" ]]; then
        echo "You must accept the End User License Agreement or provide your own license before this container can start."
        exit 1
      fi
  fi;
}

function copy_db_driver {
  case ${XL_DB_URL} in
    jdbc:h2:*)
      XL_DB_DRIVER="org.h2.Driver"
      cp ${APP_ROOT}/db-libs/h2* ${APP_HOME}/lib
      ;;
    jdbc:oracle:*)
      XL_DB_DRIVER="oracle.jdbc.OracleDriver"
      echo "oracle jdbc driver is not provided by default in the classpath, please make sure you provide one. Please refer readme for more details"
      ;;
    jdbc:mysql:*)
      XL_DB_DRIVER="com.mysql.jdbc.Driver"
      cp ${APP_ROOT}/db-libs/mysql* ${APP_HOME}/lib
      ;;
    jdbc:postgresql:*)
      XL_DB_DRIVER="org.postgresql.Driver"
      cp ${APP_ROOT}/db-libs/postgresql* ${APP_HOME}/lib
      ;;
    jdbc:sqlserver:*)
      XL_DB_DRIVER="com.microsoft.sqlserver.jdbc.SQLServerDriver"
      cp ${APP_ROOT}/db-libs/mssql* ${APP_HOME}/lib
      ;;
    jdbc:db2:*)
      XL_DB_DRIVER="com.ibm.db2.jcc.DB2Driver"
      echo "db2 jdbc driver is not provided by default in the classpath, please make sure you provide one. Please refer readme for more details"
      ;;
    *)
        echo "Database type could not be inferred from url '${XL_REPO_DB_URL}', supported db types are 'h2', 'oracle', 'mysql', 'postgresql', 'sqlserver', 'db2'"
        exit 1
        ;;
  esac
}

function store_license {
  if [ -f "${APP_HOME}/conf/deployit-license.lic" ]; then
    echo "Pre-existing license found, not overwriting"
    return
  fi

  if [ -v XL_LICENSE ]; then
    echo "License has been explicitly provided in \${XL_LICENSE}. Using it"
    echo ${XL_LICENSE} > ${APP_HOME}/conf/deployit-license.lic
    return
  fi

  if [ $XL_LICENSE_KIND != "byol" ]; then
    echo "License kind '$XL_LICENSE_KIND' has been configured, not requesting trial license"
    return
  fi


  if [ ! -v XL_NO_UNREGISTERED_LICENSE ]; then
    echo "XL_NO_UNREGISTERED_LICENSE was not set. Requesting unregistered license"
    SERVER_PATH_PART=${XL_LICENSE_ENDPOINT:-https://download.xebialabs.com}
    echo -e $(curl -X POST "${SERVER_PATH_PART}/api/unregistered/xl-deploy" | jq --raw-output .license) | base64 -di >> ${APP_HOME}/conf/deployit-license.lic
    return
  fi
}

function generate_node_conf {
  echo "Re-generate node cluster configuration"
  HOSTNAME=$(hostname)
  IP_ADDRESS=$(hostname -i)
  
    if [ -e ${APP_HOME}/node-conf/xl-deploy.conf.template ]; then
      sed -e "s#\${XL_DB_DRIVER}#${XL_DB_DRIVER}#g" \
          -e "s#\${HOSTNAME}#${HOSTNAME}#g" \
          -e "s#\${XL_NODE_NAME}#${IP_ADDRESS}#g" \
          -e "s#\${XL_CLUSTER_MODE}#${XL_CLUSTER_MODE}#g" \
          -e "s#\${XL_DB_URL}#${XL_DB_URL}#g" \
          -e "s#\${XL_DB_USERNAME}#${XL_DB_USERNAME}#g" \
          -e "s#\${XL_DB_PASSWORD}#${XL_DB_PASSWORD}#g" \
          -e "s#\${XL_METRICS_ENABLED}#${XL_METRICS_ENABLED}#g" \
          -e "s#\${XLD_IN_PROCESS}#${XLD_IN_PROCESS}#g" \
          -e "s#\${HOSTNAME_SUFFIX}#${HOSTNAME_SUFFIX}#g" \
          -e "s#\${XL_LICENSE_KIND}#${XL_LICENSE_KIND}#g" \
      ${APP_HOME}/node-conf/xl-deploy.conf.template > ${APP_HOME}/node-conf/xl-deploy.conf
    fi
  
}

function generate_product_conf {
  if [ -z "$XL_DB_URL" ]; then
    echo "... Using default conf/xl-deploy.conf"
    return
  fi

  if [ -e ${APP_HOME}/default-conf/xl-deploy.conf.template ]; then
    echo "Generate configuration file xl-deploy.conf from environment parameters"
    sed -e "s#\${XL_DB_DRIVER}#${XL_DB_DRIVER}#g" \
        -e "s#\${XL_CLUSTER_MODE}#${XL_CLUSTER_MODE}#g" \
        -e "s#\${XL_DB_URL}#${XL_DB_URL}#g" \
        -e "s#\${XL_DB_USERNAME}#${XL_DB_USERNAME}#g" \
        -e "s#\${XL_DB_PASSWORD}#${XL_DB_PASSWORD}#g" \
        -e "s#\${XL_METRICS_ENABLED}#${XL_METRICS_ENABLED}#g" \
        -e "s#\${XLD_IN_PROCESS}#${XLD_IN_PROCESS}#g" \
        -e "s#\${HOSTNAME_SUFFIX}#${HOSTNAME_SUFFIX}#g" \
        -e "s#\${XL_LICENSE_KIND}#${XL_LICENSE_KIND}#g" \
    ${APP_HOME}/default-conf/xl-deploy.conf.template > ${APP_HOME}/conf/xl-deploy.conf
  fi
}

function check_force_upgrade {
   FORCE_UPGRADE_FLAG=""
   if [[ ${FORCE_UPGRADE,,} == "true" ]] ; then
     echo "Force upgrade setting has been detected. In case of upgrade it will be performed in non-interactive mode. "
     FORCE_UPGRADE_FLAG="-force-upgrades"
   fi
}
# Copy default plugins
if [ -z "$(ls -A ${APP_HOME}/plugins)" ]; then
  echo "Empty ${APP_HOME}/plugins directory detected:"
  echo "... Copying default plugins from ${APP_HOME}/default-plugins"

  cd ${APP_HOME}/default-plugins
  for pluginjar in *; do
    pluginbasename=${pluginjar%%-[0-9\.]*.jar}
    if [ -f ${APP_HOME}/plugins/*/$pluginbasename-[0-9\.]*.jar ]; then
      echo "... Not copying $pluginrepo/$pluginjar because a version of that plugin already exists in the plugins directory"
    else
      cp -R ${APP_HOME}/default-plugins/$pluginrepo/$pluginjar ${APP_HOME}/plugins/$pluginrepo/
    fi
  done
  cd ${APP_HOME}

  echo "Done"
fi

# Set up new installation
if [ ! -f "${APP_HOME}/conf/deployit.conf" ]; then
  echo "No ${APP_HOME}/conf/deployit.conf file detected:"
  echo "... Copying default configuration from ${APP_HOME}/default-conf"

  cd ${APP_HOME}/default-conf
  for f in *; do
    if [[ $f == *.template ]]; then
      continue
    fi
    if [ -f ${APP_HOME}/conf/$f ]; then
      echo "... Not copying $f because it already exists in the conf directory"
    else
      cp -R $f ${APP_HOME}/conf/
    fi
  done
  cd ${APP_HOME}

  echo "Done"

  if [ $# -eq 0 ] || [ $1 == "worker" ]; then
    echo "No arguments passed to container:"
    echo "... Running default setup"

    if [ "${ADMIN_PASSWORD}" = "" ]; then
      ADMIN_PASSWORD=`pwgen 8`
      echo "... Generating admin password: ${ADMIN_PASSWORD}"
    fi

    if [ "${REPOSITORY_KEYSTORE}" = "" ]; then
      if [ "${REPOSITORY_KEYSTORE_PASSPHRASE}" = "" ]; then
        REPOSITORY_KEYSTORE_PASSPHRASE=`pwgen 16`
        echo "... Generating repository keystore passphrase: ${REPOSITORY_KEYSTORE_PASSPHRASE}"
      fi
      echo "... Generating repository keystore"
      keytool -genseckey -alias deployit-passsword-key -keyalg aes -keysize 128 -keypass "deployit" -keystore ${APP_HOME}/conf/repository-keystore.jceks -storetype jceks -storepass ${REPOSITORY_KEYSTORE_PASSPHRASE}
    else
      echo ${REPOSITORY_KEYSTORE} | base64 -d > ${APP_HOME}/conf/repository-keystore.jceks
    fi

    echo "... Generating deployit.conf"
    sed -e "s#\${ADMIN_PASSWORD}#${ADMIN_PASSWORD}#g" -e "s#\${REPOSITORY_KEYSTORE_PASSPHRASE}#${REPOSITORY_KEYSTORE_PASSPHRASE}#g" ${APP_HOME}/default-conf/deployit.conf.template > ${APP_HOME}/conf/deployit.conf

    echo "Done"
  fi
fi

check_eula
copy_db_driver
generate_product_conf
generate_node_conf
store_license
check_force_upgrade

# Start regular startup process
exec ${APP_HOME}/bin/run.sh ${FORCE_UPGRADE_FLAG} "$@"