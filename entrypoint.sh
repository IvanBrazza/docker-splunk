#!/bin/bash

set -e

if [ "$1" = 'splunk' ]; then
  shift
  sudo -HEu ${SPLUNK_USER} ${SPLUNK_HOME}/bin/splunk "$@"
elif [ "$1" = 'start-service' ]; then
  # If user changed SPLUNK_USER to root we want to change permission for SPLUNK_HOME
  if [[ "${SPLUNK_USER}:${SPLUNK_GROUP}" != "$(stat --format %U:%G ${SPLUNK_HOME})" ]]; then
    chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} ${SPLUNK_HOME}
  fi

  # If version file exists already - this Splunk has been configured before
  __configured=false
  if [[ -f ${SPLUNK_HOME}/etc/splunk.version ]]; then
    __configured=true
  fi

  __license_ok=false
  # If these files are different override etc folder (possible that this is upgrade or first start cases)
  # Also override ownership of these files to splunk:splunk
  if ! $(cmp --silent /var/opt/splunk/etc/splunk.version ${SPLUNK_HOME}/etc/splunk.version); then
    cp -fR /var/opt/splunk/etc ${SPLUNK_HOME}
    chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} ${SPLUNK_HOME}/etc
    chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} ${SPLUNK_HOME}/var
  else
    __license_ok=true
  fi

  if tty -s; then
    __license_ok=true
  fi

  if [[ "$SPLUNK_START_ARGS" == *"--accept-license"* ]]; then
    __license_ok=true
  fi

  if [[ "$SPLUNK_ACCEPT_LICENSE" == "true" ]]; then
    SPLUNK_START_ARGS="$SPLUNK_START_ARGS --accept-license"
    __license_ok=true
  fi

  if [[ $__license_ok == "false" ]]; then
    cat << EOF
Splunk Enterprise
==============

  Available Options:

      - Launch container in Interactive mode "-it" to review and accept
        end user license agreement
      - If you have reviewed and accepted the license, start container
        with the environment variable:
            SPLUNK_START_ARGS=--accept-license

  Usage:

    docker run -it splunk/enterprise:6.4.1
    docker run --env SPLUNK_START_ARGS="--accept-license" splunk/enterprise:6.4.1

EOF
    exit 1
  fi

  if [[ $__configured == "false" ]]; then
    # If we have not configured yet allow user to specify some commands which can be executed before we start Splunk for the first time
    if [[ -n ${SPLUNK_BEFORE_START_CMD} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk ${SPLUNK_BEFORE_START_CMD}"
    fi
    for n in {1..30}; do
      if [[ -n $(eval echo \$\{SPLUNK_BEFORE_START_CMD_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk $(eval echo \$\{SPLUNK_BEFORE_START_CMD_${n}\})"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done
  fi

  sudo -HEu ${SPLUNK_USER} ${SPLUNK_HOME}/bin/splunk start ${SPLUNK_START_ARGS}
  trap "sudo -HEu ${SPLUNK_USER} ${SPLUNK_HOME}/bin/splunk stop" SIGINT SIGTERM EXIT

  # If this is first time we start this splunk instance
  if [[ $__configured == "false" ]]; then
    __restart_required=false

    # Setup deployment server
    if [[ ${SPLUNK_ENABLE_DEPLOY_SERVER} == "true" ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk enable deploy-server -auth admin:changeme"
      __restart_required=true
    fi

    # Setup deployment client
    # http://docs.splunk.com/Documentation/Splunk/latest/Updating/Configuredeploymentclients
    if [[ -n ${SPLUNK_DEPLOYMENT_SERVER} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk set deploy-poll ${SPLUNK_DEPLOYMENT_SERVER} -auth admin:changeme"
      __restart_required=true
    fi

    if [[ -n ${SPLUNK_NODE_TYPE} ]]; then
      case ${SPLUNK_NODE_TYPE} in
        master_node)
          # Validate required vars
          if [[ -z ${SPLUNK_REPLICATION_FACTOR} ]]; then
            cat "SPLUNK_REPLICATION_FACTOR not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_SEARCH_FACTOR} ]]; then
            cat "SPLUNK_SEARCH_FACTOR not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_SECRET} ]]; then
            cat "SPLUNK_SECRET not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_CLUSTER_LABEL} ]]; then
            cat "SPLUNK_CLUSTER_LABEL not set!"
            exit 1
          fi
          sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk edit cluster-config -mode master -replication_factor ${SPLUNK_REPLICATION_FACTOR} -search_factor ${SPLUNK_SEARCH_FACTOR} -secret ${SPLUNK_SECRET} -cluster_label ${SPLUNK_CLUSTER_LABEL} -auth admin:changeme"
          ;;
        indexer_cluster_peer)
          # Validate required vars
          if [[ -z ${SPLUNK_MASTER_URI} ]]; then
            cat "SPLUNK_MASTER_URI not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_REPLICATION_PORT} ]]; then
            cat "SPLUNK_REPLICATION_PORT not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_SECRET} ]]; then
            cat "SPLUNK_SECRET not set!"
            exit 1
          fi
          echo "Waiting for ${SPLUNK_MASTER_URI} to be available..."
          while ! sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk edit cluster-config -mode slave -master_uri https://${SPLUNK_MASTER_URI} -replication_port ${SPLUNK_REPLICATION_PORT} -secret ${SPLUNK_SECRET} -auth admin:changeme"; do sleep 10; done
          ;;
        search_head_cluster_deployer)
          # Validate required vars
          if [[ -z ${SPLUNK_SECRET} ]]; then
            cat "SPLUNK_SECRET not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_CLUSTER_LABEL} ]]; then
            cat "SPLUNK_CLUSTER_LABEL not set!"
            exit 1
          fi
          cat >> ${SPLUNK_HOME}/etc/system/local/server.conf <<EOL
[shclustering]
pass4SymmKey = ${SPLUNK_SECRET}
shcluster_label = ${SPLUNK_CLUSTER_LABEL}
EOL
          ;;
        search_head_cluster_peer)
          # Validate required vars
          if [[ -z ${SPLUNK_MGMT_URI} ]]; then
            cat "SPLUNK_MGMT_URI not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_REPLICATION_PORT} ]]; then
            cat "SPLUNK_REPLICATION_PORT not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_REPLICATION_FACTOR} ]]; then
            cat "SPLUNK_REPLICATION_FACTOR not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_DEPLOYER_URL} ]]; then
            cat "SPLUNK_DEPLOYER_URL not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_SECRET} ]]; then
            cat "SPLUNK_SECRET not set!"
            exit 1
          fi
          if [[ -z ${SPLUNK_CLUSTER_LABEL} ]]; then
            cat "SPLUNK_CLUSTER_LABEL not set!"
            exit 1
          fi
          sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk init shcluster-config -auth admin:changeme -mgmt_uri https://${SPLUNK_MGMT_URI} -replication_port ${SPLUNK_REPLICATION_PORT} -replication_factor ${SPLUNK_REPLICATION_FACTOR} -conf_deploy_fetch_url https://${SPLUNK_DEPLOYER_URL} -secret ${SPLUNK_SECRET} -shcluster_label ${SPLUNK_CLUSTER_LABEL}  -auth admin:changeme"
          if [[ -n ${SPLUNK_MASTER_URI} ]]; then
            sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk edit cluster-config -mode searchhead -master_uri https://${SPLUNK_MASTER_URI} -secret ${SPLUNK_SECRET} -auth admin:changeme"
          fi
          ;;
      esac
      __restart_required=true
    fi

    if [[ "$__restart_required" == "true" ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk restart"
    fi

    if [[ -n ${SPLUNK_BOOTSTRAP_CAPTAIN} ]]; then
      if [[ ${SPLUNK_BOOTSTRAP_CAPTAIN} -eq "true" ]]; then
        # Validate required vars
        if [[ -z ${SPLUNK_SHCLUSTER_SERVER_LIST} ]]; then
          cat "SPLUNK_SHCLUSTER_SERVER_LIST not set!"
          exit 1
        fi
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk bootstrap shcluster-captain -servers_list ${SPLUNK_SHCLUSTER_SERVER_LIST} -auth admin:changeme"
      fi
    fi

    # Setup listening
    # http://docs.splunk.com/Documentation/Splunk/latest/Forwarding/Enableareceiver
    if [[ -n ${SPLUNK_ENABLE_LISTEN} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk enable listen ${SPLUNK_ENABLE_LISTEN} -auth admin:changeme ${SPLUNK_ENABLE_LISTEN_ARGS}"
    fi

    # Setup forwarding server
    # http://docs.splunk.com/Documentation/Splunk/latest/Forwarding/Deployanixdfmanually
    if [[ -n ${SPLUNK_FORWARD_SERVER} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add forward-server ${SPLUNK_FORWARD_SERVER} -auth admin:changeme ${SPLUNK_FORWARD_SERVER_ARGS}"
    fi
    for n in {1..10}; do
      if [[ -n $(eval echo \$\{SPLUNK_FORWARD_SERVER_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add forward-server $(eval echo \$\{SPLUNK_FORWARD_SERVER_${n}\}) -auth admin:changeme $(eval echo \$\{SPLUNK_FORWARD_SERVER_${n}_ARGS\})"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done

    # Setup monitoring
    # http://docs.splunk.com/Documentation/Splunk/latest/Data/MonitorfilesanddirectoriesusingtheCLI
    # http://docs.splunk.com/Documentation/Splunk/latest/Data/Monitornetworkports
    if [[ -n ${SPLUNK_ADD} ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add ${SPLUNK_ADD} -auth admin:changeme"
    fi
    for n in {1..30}; do
      if [[ -n $(eval echo \$\{SPLUNK_ADD_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add $(eval echo \$\{SPLUNK_ADD_${n}\}) -auth admin:changeme"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done

    # Execute anything
    if [[ -n ${SPLUNK_CMD} ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk ${SPLUNK_CMD}"
    fi
    for n in {1..30}; do
      if [[ -n $(eval echo \$\{SPLUNK_CMD_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk $(eval echo \$\{SPLUNK_CMD_${n}\})"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done
  fi

  sudo -HEu ${SPLUNK_USER} tail -n 0 -f ${SPLUNK_HOME}/var/log/splunk/splunkd_stderr.log &
  wait
elif [ "$1" = 'splunk-bash' ]; then
  sudo -u ${SPLUNK_USER} /bin/bash --init-file ${SPLUNK_HOME}/bin/setSplunkEnv
else
  "$@"
fi
