#!/bin/bash

help() {
    echo "Setup and run a Couchbase cluster node. Uses Consul to find other"
    echo "nodes in the cluster or bootstraps the cluster if it does not yet"
    echo "exist."
    echo
    echo "Usage: ./manage.sh health    => runs health check and bootstrap."
    echo "       ./manage.sh <command> => run another function for debugging."
}

trap cleanup EXIT

# This container's private IP
IP_PRIVATE=$(ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
export IP_PRIVATE
# Discovery vars
COUCHBASE_SERVICE_NAME=${COUCHBASE_SERVICE_NAME:-couchbase-api}
export CONSUL=${CONSUL:-consul}

# Couchbase username and password
export COUCHBASE_USER=${COUCHBASE_USER:-Administrator}
export COUCHBASE_PASS=${COUCHBASE_PASS:-password}
CB_CONN="-c 127.0.0.1:8091 -u ${COUCHBASE_USER} -p ${COUCHBASE_PASS}"

# Set all services as default and verify that those are the only options allowed
export COUCHBASE_SERVICES=${COUCHBASE_SERVICES:-data,index,query}
RGE=$(
    grep -Fxv -f \
        <(echo -n "data,index,query" | tr , "\n") \
        <(echo -n "$COUCHBASE_SERVICES" | tr , "\n")
)

if [ "$RGE" != "" ]; then
    echo "Unknown couchbase service '$(echo -n "$RGE" \
        | tr "\n" , )'. Only 'data', 'index' and 'query' are supported"
    exit 1
fi
# -------------------------------------------
# Top-level health check handler


health() {
    # if we're already initialized and joined to a cluster,
    # we can just run the health check and exit
    checkLock
    initNode
    isNodeInCluster
    if [ $? -eq 0 ]; then
        doHealthCheck
        exit $?
    fi

    # if there is a healthy cluster we join it, otherwise we try
    # to create a new cluster. If another node is in the process
    # of creating a new cluster, we'll wait for it instead.
    echo 'Looking for an existing cluster...'
    while true; do
        local node
        node=$(getHealthyClusterIp)
        if [[ ${node} != "null" ]]; then
            joinCluster "$node"
        else
            obtainBootstrapLock
            if [ $? -eq 0 ]; then
                initCluster
            else
                sleep 3
            fi
        fi
    done
}


# -------------------------------------------
# Status checking


# The couchbase-cli provides no documented mechanism to verify that we've
# initialized the node. But if we try to node-init with the default password
# and it fails, then we know we've previously initialized this node.
# Either way we can merrily continue.
initNode() {
    # couchbase takes a while to become responsive on start, so we need to
    # make sure it's up first.
    while true; do
        # an uninitialized node will have default creds
        couchbase-cli server-info -c 127.0.0.1:8091 -u access -p password &>/dev/null
        if [ $? -eq 0 ]; then
            break
        fi
        # check the initialized creds as well
        couchbase-cli server-info "${CB_CONN}" &>/dev/null
        if [ $? -eq 0 ]; then
            break
        fi
        echo -n '.'
        sleep 1
    done
    couchbase-cli node-init -c 127.0.0.1:8091 -u access -p password \
                  --node-init-data-path=/opt/couchbase/var/lib/couchbase/data \
                  --node-init-index-path=/opt/couchbase/var/lib/couchbase/data \
                  --node-init-hostname="${IP_PRIVATE}" &>/dev/null \
        && echo '# Node initialized'
}

isNodeInCluster() {
    couchbase-cli server-list "${CB_CONN}" | grep "${IP_PRIVATE}" &>/dev/null
    return $?
}

doHealthCheck() {
    local status
    status=$(couchbase-cli server-info "${CB_CONN}" | jq -r .status)
    if [[ $status != "healthy" ]]; then
       echo "Node not healthy, status was: $status"
       return 1
    fi
    return 0
}


# -------------------------------------------
# Joining a cluster


# We only need one IP from the healthy cluster in order to join it.
getHealthyClusterIp() {
    curl -Lsf "http://${CONSUL}:8500/v1/health/service/${COUCHBASE_SERVICE_NAME}?passing" | jq -r .[0].Service.Address
}

# If we fail to join the cluster, then bail out and hit it on the
# next health check
joinCluster(){
    echo '# Joining cluster...'
    local node=$1
    curl -Lsif -u "${COUCHBASE_USER}:${COUCHBASE_PASS}" \
         -d "hostname=${IP_PRIVATE}&user=admin&password=password" \
         "http://${node}:8091/controller/addNode" || exit 1
    echo 'Joined cluster!'
    rebalance
    exit 0
}

# We need to rebalance for each node because we can't guarantee that we won't
# try to rebalance while another node is coming up. Doing this in a loop because
# we can't queue-up rebalances -- the rebalance command cannot be called while a
# rebalance is in progress
rebalance() {
    echo '# Rebalancing cluster...'
    while true; do
        echo -n '.'
        couchbase-cli rebalance "${CB_CONN}" && return
        sleep .7
    done
}


# -------------------------------------------
# Bootstrapping a cluster

# Try to obtain a lock in Consul. If we can't get the lock then another node
# is trying to bootstrap the cluster. The cluster-init node will have 120s
# to show up as healthy in Consul.
obtainBootstrapLock() {
    echo 'No cluster nodes found, trying to obtain lock on bootstrap...'
    local session
    session=$(curl -Lsf -XPUT -d '{"Name": "couchbase-bootstrap", "TTL": "120s"}' "http://${CONSUL}:8500/v1/session/create" | jq -r .ID) || return $?
    local lock
    lock=$(curl -Lsf -XPUT "http://${CONSUL}:8500/v1/kv/couchbase-bootstrap?acquire=$session")
    if [[ $lock == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# bootstrap the Couchbase cluster and set resource limits
initCluster() {
    echo
    echo '# Bootstrapping cluster...'

    # Couchbase resource limits
    local avail_memory
    avail_memory=$(free -m | grep -o "Mem:\s*[0-9]*" | grep -o "[0-9]*")
    local cb_memory
    cb_memory=$(( (avail_memory / 10) * 7 ))

    couchbase-cli cluster-init -c 127.0.0.1:8091 -u access -p password \
                  --cluster-init-username="${COUCHBASE_USER}" \
                  --cluster-init-password="${COUCHBASE_PASS}" \
                  --cluster-init-port=8091 \
                  --cluster-init-ramsize="${cb_memory}" \
                  --services="$COUCHBASE_SERVICES"

    echo '# Cluster bootstrapped'
    echo
    exit 0
}

# filters JSON coming back from REST API for this node with argument. examples:
# stats mcdMemoryAllocated
# stats systemStats.mem_free
stats() {
    curl -s --fail -u "${COUCHBASE_USER}:${COUCHBASE_PASS}" \
         http://127.0.0.1:8091/pools/default | \
        jq -r "$(printf '.nodes[] | select(.hostname | contains("%s")) | .%s' "${IP_PRIVATE}" "$1")"
}


# -------------------------------------------
# helpers

# make sure we're running only one init process at a time
# even with overlapping health check handlers
checkLock() {
    if ! mkdir /var/lock/couchbase-init; then
        echo 'couchbase-init lock in place, skipping'
    fi
}

cleanup() {
    rm -rf /var/lock/couchbase-init
}

# -------------------------------------------

until
    cmd=$1
    if [ -z "$cmd" ]; then
        help
    fi
    shift 1
    $cmd "$@"
    [ "$?" -ne 127 ]
do
    help
    exit
done
