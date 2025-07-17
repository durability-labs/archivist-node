#!/bin/bash

# Environment variables from files in form of foo=bar
# If set to file path, read the file and export the variables
# If set to directory path, read all files in the directory and export the variables
if [[ -n "${ENV_PATH}" ]]; then
  set -a
  [[ -f "${ENV_PATH}" ]] && source "${ENV_PATH}" || for f in "${ENV_PATH}"/*; do source "$f"; done
  set +a
fi

# Network
if [[ -n "${NETWORK}" ]]; then
  BOOTSTRAP_SERVICE_URL=https://spr.example.com #TODO
  export BOOTSTRAP_NODE_FROM_URL="${BOOTSTRAP_NODE_FROM_URL:-${BOOTSTRAP_SERVICE_URL}/${NETWORK}}"
fi

# Bootstrap node URL
if [[ -n "${BOOTSTRAP_NODE_URL}" ]]; then
  BOOTSTRAP_NODE_URL="${BOOTSTRAP_NODE_URL}/api/archivist/v1/spr"
  WAIT=${BOOTSTRAP_NODE_URL_WAIT:-300}
  SECONDS=0
  SLEEP=1
  # Run and retry if fail
  while (( SECONDS < WAIT )); do
    SPR=$(curl -s -f -m 5 -H 'Accept: text/plain' "${BOOTSTRAP_NODE_URL}")
    # Check if exit code is 0 and returned value is not empty
    if [[ $? -eq 0 && -n "${SPR}" ]]; then
      export ARCHIVIST_BOOTSTRAP_NODE="${SPR}"
      break
    else
      # Sleep and check again
      echo "Can't get SPR from ${BOOTSTRAP_NODE_URL} - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
      sleep $SLEEP
    fi
  done
fi

# Bootstrap node from URL
if [[ -n "${BOOTSTRAP_NODE_FROM_URL}" ]]; then
  WAIT=${BOOTSTRAP_NODE_FROM_URL_WAIT:-300}
  SECONDS=0
  SLEEP=1
  # Run and retry if fail
  while (( SECONDS < WAIT )); do
    SPR=($(curl -s -f -m 5 "${BOOTSTRAP_NODE_FROM_URL}"))
    # Check if exit code is 0 and returned value is not empty
    if [[ $? -eq 0 && -n "${SPR}" ]]; then
      for node in "${SPR[@]}"; do
        bootstrap+="--bootstrap-node=$node "
      done
      set -- "$@" ${bootstrap}
      break
    else
      # Sleep and check again
      echo "Can't get SPR from ${BOOTSTRAP_NODE_FROM_URL} - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
      sleep $SLEEP
    fi
  done
fi

# Marketplace address from URL
if [[ -n "${MARKETPLACE_ADDRESS_FROM_URL}" ]]; then
  WAIT=${MARKETPLACE_ADDRESS_FROM_URL_WAIT:-300}
  SECONDS=0
  SLEEP=1
  # Run and retry if fail
  while (( SECONDS < WAIT )); do
    MARKETPLACE_ADDRESS=($(curl -s -f -m 5 "${MARKETPLACE_ADDRESS_FROM_URL}"))
    # Check if exit code is 0 and returned value is not empty
    if [[ $? -eq 0 && -n "${MARKETPLACE_ADDRESS}" ]]; then
      export ARCHIVIST_MARKETPLACE_ADDRESS="${MARKETPLACE_ADDRESS}"
      break
    else
      # Sleep and check again
      echo "Can't get Marketplace address from ${MARKETPLACE_ADDRESS_FROM_URL} - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
      sleep $SLEEP
    fi
  done
fi

# Stop node run if unable to get SPR
if [[ -n "${BOOTSTRAP_NODE_URL}" && -z "${ARCHIVIST_BOOTSTRAP_NODE}" ]]; then
  echo "Unable to get SPR from ${BOOTSTRAP_NODE_URL} in ${BOOTSTRAP_NODE_URL_WAIT} seconds - Stop node run"
  exit 1
fi

# Parameters
if [[ -z "${ARCHIVIST_NAT}" ]]; then
  if [[ "${NAT_IP_AUTO}" == "true" && -z "${NAT_PUBLIC_IP_AUTO}" ]]; then
    export ARCHIVIST_NAT="extip:$(hostname --ip-address)"
  elif [[ -n "${NAT_PUBLIC_IP_AUTO}" ]]; then
    # Run for 60 seconds if fail
    WAIT=120
    SECONDS=0
    SLEEP=5
    while (( SECONDS < WAIT )); do
      IP=$(curl -s -f -m 5 "${NAT_PUBLIC_IP_AUTO}")
      # Check if exit code is 0 and returned value is not empty
      if [[ $? -eq 0 && -n "${IP}" ]]; then
        export ARCHIVIST_NAT="extip:${IP}"
        break
      else
        # Sleep and check again
        echo "Can't get Public IP - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
        sleep $SLEEP
      fi
    done
  fi
fi

# Stop node run if can't get NAT IP when requested
if [[ "${NAT_IP_AUTO}" == "true" && -z "${ARCHIVIST_NAT}" ]]; then
  echo "Can't get Private IP - Stop node run"
  exit 1
elif [[ -n "${NAT_PUBLIC_IP_AUTO}" && -z "${ARCHIVIST_NAT}" ]]; then
  echo "Can't get Public IP in $WAIT seconds - Stop node run"
  exit 1
fi

# If marketplace is enabled from the testing environment,
# The file has to be written before the node starts.
keyfile="private.key"
if [[ -n "${ETH_PRIVATE_KEY}" ]]; then
  echo "${ETH_PRIVATE_KEY}" > "${keyfile}"
  chmod 600 "${keyfile}"
  export ARCHIVIST_ETH_PRIVATE_KEY="${keyfile}"
  echo "Private key set"
fi

# Circuit downloader
# cirdl [circuitPath] [rpcEndpoint] [marketplaceAddress]
if [[ "$@" == *"prover"* ]]; then
  echo "Prover is enabled - Run Circuit downloader"

  # Set variables required by cirdl from command line arguments when passed
  for arg in data-dir circuit-dir eth-provider marketplace-address; do
    arg_value=$(grep -o "${arg}=[^ ,]\+" <<< $@ | awk -F '=' '{print $2}')
    if [[ -n "${arg_value}" ]]; then
      var_name=$(tr '[:lower:]' '[:upper:]' <<< "ARCHIVIST_${arg//-/_}")
      export "${var_name}"="${arg_value}"
    fi
  done

  # Set circuit dir from ARCHIVIST_CIRCUIT_DIR variables if set
  if [[ -z "${ARCHIVIST_CIRCUIT_DIR}" ]]; then
    export ARCHIVIST_CIRCUIT_DIR="${ARCHIVIST_DATA_DIR}/circuits"
  fi

  # Download circuit
  mkdir -p "${ARCHIVIST_CIRCUIT_DIR}"
  chmod 700 "${ARCHIVIST_CIRCUIT_DIR}"
  download="cirdl ${ARCHIVIST_CIRCUIT_DIR} ${ARCHIVIST_ETH_PROVIDER} ${ARCHIVIST_MARKETPLACE_ADDRESS}"
  echo "${download}"
  eval "${download}"
  [[ $? -ne 0 ]] && { echo "Failed to download circuit files"; exit 1; }
fi

# Show
echo -e "\nnode run parameters:"
vars=$(env | grep "ARCHIVIST_" | grep -v -e "[0-9]_SERVICE_" -e "[0-9]_NODEPORT_")
echo -e "${vars//ARCHIVIST_/   - ARCHIVIST_}"
echo -e "   - $@\n"

# Run
echo "Run node"
exec "$@"
