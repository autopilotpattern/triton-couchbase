#!/bin/bash

#
# This script is run once on startup to find and join a Couchbase cluster
# it will continue polling for a cluster until one is found
#
# The script can also be run with arguments to bootstrap the cluster
#

# This container's IP(s)
export IP_PRIVATE=$(ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
IP_HAVEPUBLIC=$(ip link show | grep eth1)
if [[ $IP_HAVEPUBLIC ]]
then
    export IP_PUBLIC=$(ip addr show eth1 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
else
    export IP_PUBLIC=$IP_PRIVATE
fi

# Discovery vars
export COUCHBASE_SERVICE_NAME=${COUCHBASE_SERVICE_NAME:-couchbase}
export CONSUL_HOST=${CONSUL_HOST:-'http://consul:8500'}

# Couchbase username and password
export COUCHBASE_USER=${COUCHBASE_USER:-Administrator}
export COUCHBASE_PASS=${COUCHBASE_PASS:-password}

# The bucket to create when bootstrapping
export COUCHBASE_BUCKET=$2

# Couchbase resource limits
export AVAIL_MEMORY=$(free -m | grep -o "Mem:\s*[0-9]*" | grep -o "[0-9]*")
export AVAIL_CPUS=$(nproc)
export COUCHBASE_CPUS=$(($AVAIL_CPUS>8?8:$AVAIL_CPUS))
export COUCHBASE_CPUS=$(($COUCHBASE_CPUS>1?$COUCHBASE_CPUS:1))
export COUCHBASE_NS_SERVER_VM_EXTRA_ARGS=$(printf '["+S", "%s"]' $COUCHBASE_CPUS)
export ERL_AFLAGS="+S $COUCHBASE_CPUS"
export GOMAXPROCS=$COUCHBASE_CPUS
export COUCHBASE_MEMORY=$((($AVAIL_MEMORY/10)*7))

installed ()
{
    echo
    echo '#'
    echo '# Couchbase is installed and configured'
    echo '#'
    echo "#   Dashboard: http://$IP_PUBLIC:8091"
    echo "# Internal IP: $IP_PRIVATE"
    echo "#    Username: $COUCHBASE_USER"
    echo "#    Password: $COUCHBASE_PASS"
    echo '#'
}


# rest a moment while Couchabase starts (it's started from triton-start.)
sleep 1.3

echo
echo '#'
echo '# Testing to see if Couchbase is running yet'
echo '#'

COUCHBASERESPONSIVE=0
while [ $COUCHBASERESPONSIVE != 1 ]; do
    echo -n '.'

    # test the default u/p
    couchbase-cli server-info -c 127.0.0.1:8091 -u access -p password &> /dev/null
    if [ $? -eq 0 ]; then
        let COUCHBASERESPONSIVE=1
    fi

    # test the alternate u/p
    couchbase-cli server-info -c 127.0.0.1:8091 -u $COUCHBASE_USER -p $COUCHBASE_PASS &> /dev/null
    if [ $? -eq 0 ]
    then
        let COUCHBASERESPONSIVE=1
    else
        sleep .7
    fi
done
sleep 1

# it's responsive, is it already configured?
couchbase-cli server-list -c 127.0.0.1:8091 -u $COUCHBASE_USER -p $COUCHBASE_PASS &> /dev/null
if [ $? -eq 0 ]; then
    echo
    echo '#'
    echo '# Already joined to cluster...'
    echo '#'
    installed

    exit
fi

echo
echo '#'
echo '# Checking Consul availability'
echo '#'

curl -fs --retry 7 --retry-delay 3 $CONSUL_HOST/v1/agent/services &> /dev/null
if [ $? -ne 0 ]
then
    echo '#'
    echo '# Consul is required, but unreachable'
    echo '#'
    curl $CONSUL_HOST/v1/agent/services
    exit
else
    echo '# Consul instance found and responsive'
    echo '#'
fi

#
# Register this unconfigured Couchbase instance in Consul for discovery by the configuration/bootstrap agent
#
curl -f --retry 7 --retry-delay 3 $CONSUL_HOST/v1/agent/service/register -d "$(printf '{"ID":"%s-unconfigured-%s","Name":"%s-unconfigured","Address":"%s","checks": [{"ttl": "5900s"}]}' $COUCHBASE_SERVICE_NAME $HOSTNAME $COUCHBASE_SERVICE_NAME $IP_PRIVATE)"

# pass the healthcheck
curl -f --retry 7 --retry-delay 3 "$CONSUL_HOST/v1/agent/check/pass/service:$COUCHBASE_SERVICE_NAME-unconfigured-$HOSTNAME?note=initial+startup"



COUCHBASERESPONSIVE=0
while [ $COUCHBASERESPONSIVE != 1 ]; do
    echo -n '.'

    # test the default u/p
    couchbase-cli server-info -c 127.0.0.1:8091 -u access -p password &> /dev/null
    if [ $? -eq 0 ]; then
        let COUCHBASERESPONSIVE=1
    fi

    # test the alternate u/p
    couchbase-cli server-info -c 127.0.0.1:8091 -u $COUCHBASE_USER -p $COUCHBASE_PASS &> /dev/null
    if [ $? -eq 0 ]
    then
        let COUCHBASERESPONSIVE=1
    else
        sleep .7
    fi
done
sleep 1

echo
echo '#'
echo '# Initializing node'
echo '#'

COUCHBASERESPONSIVE=0
while [ $COUCHBASERESPONSIVE != 1 ]; do
    echo -n '.'

    /opt/couchbase/bin/couchbase-cli node-init -c 127.0.0.1:8091 -u access -p password \
        --node-init-data-path=/opt/couchbase/var/lib/couchbase/data \
        --node-init-index-path=/opt/couchbase/var/lib/couchbase/data \
        --node-init-hostname=$IP_PRIVATE

    if [ $? -eq 0 ]
    then
        let COUCHBASERESPONSIVE=1
    else
        sleep .7
    fi
done
echo


if [ "$1" = 'bootstrap' ]
then
    echo '#'
    echo '# Bootstrapping cluster'
    echo '#'

    #
    # Deregister this instance from the list of unconfigured instances in Consul
    #
    curl -f --retry 7 --retry-delay 3 $CONSUL_HOST/v1/agent/service/deregister/$COUCHBASE_SERVICE_NAME-unconfigured-$HOSTNAME

    # initializing the cluster
    COUCHBASERESPONSIVE=0
    while [ $COUCHBASERESPONSIVE != 1 ]; do
        echo -n '.'

        /opt/couchbase/bin/couchbase-cli cluster-init -c 127.0.0.1:8091 -u access -p password \
            --cluster-init-username=$COUCHBASE_USER \
            --cluster-init-password=$COUCHBASE_PASS \
            --cluster-init-port=8091 \
            --cluster-init-ramsize=$COUCHBASE_MEMORY \
            --services=data,index,query

        if [ $? -eq 0 ]
        then
            let COUCHBASERESPONSIVE=1
        else
            sleep .7
        fi
    done

    # creating the bucket
    COUCHBASERESPONSIVE=0
    while [ $COUCHBASERESPONSIVE != 1 ]; do
        echo -n '.'

        /opt/couchbase/bin/couchbase-cli bucket-create -c 127.0.01:8091 -u $COUCHBASE_USER -p $COUCHBASE_PASS \
            --bucket=$COUCHBASE_BUCKET \
            --bucket-type=couchbase \
            --bucket-ramsize=$COUCHBASE_MEMORY \
            --bucket-replica=1

        if [ $? -eq 0 ]
        then
            let COUCHBASERESPONSIVE=1
        else
            sleep .7
        fi
    done

    # limit the number of threads for various operations on this bucket
    # See http://docs.couchbase.com/admin/admin/CLI/CBepctl/cbepctl-threadpool-tuning.html for more details
    /opt/couchbase/bin/cbepctl 127.0.0.1:11210 -b $COUCHBASE_BUCKET set flush_param max_num_writers $(($COUCHBASE_CPUS>1?$COUCHBASE_CPUS/2:1))
    /opt/couchbase/bin/cbepctl 127.0.0.1:11210 -b $COUCHBASE_BUCKET set flush_param max_num_readers $(($COUCHBASE_CPUS>1?$COUCHBASE_CPUS/2:1))
    /opt/couchbase/bin/cbepctl 127.0.0.1:11210 -b $COUCHBASE_BUCKET set flush_param max_num_auxio 1
    /opt/couchbase/bin/cbepctl 127.0.0.1:11210 -b $COUCHBASE_BUCKET set flush_param max_num_nonio 1

else
    echo '#'
    echo '# Looking for an existing cluster'
    echo '#'

    CLUSTERFOUND=0
    while [ $CLUSTERFOUND != 1 ]; do
        echo -n '.'

        CLUSTERIP=$(curl -L -s -f $CONSUL_HOST/v1/health/service/$COUCHBASE_SERVICE_NAME?passing | json -aH Service.Address | head -1)
        if [ -n "$CLUSTERIP" ]
        then
            let CLUSTERFOUND=1
        else
            # Update the healthcheck for this unconfigured Couchbase instance in Consul for discovery by the configuration/bootstrap agent
            curl -f --retry 7 --retry-delay 3 "$CONSUL_HOST/v1/agent/check/pass/service:$COUCHBASE_SERVICE_NAME-unconfigured-$HOSTNAME?note=polling+for+cluster"

            # sleep for a bit
            sleep 7
        fi
    done

    #
    # Deregister this instance from the list of unconfigured instances in Consul
    #
    curl -f --retry 7 --retry-delay 3 $CONSUL_HOST/v1/agent/service/deregister/$COUCHBASE_SERVICE_NAME-unconfigured-$HOSTNAME

    echo
    echo '#'
    echo '# Joining cluster...'
    echo '#'

    COUCHBASERESPONSIVE=0
    while [ $COUCHBASERESPONSIVE != 1 ]; do
        echo -n '.'

        # This is the moment that we're adding an unconfigured node to an already configured cluster.
        # We have to speak to the configured cluster ($CLUSTERIP) using the user selected u/p,
        # ...but tell it to add this new node using its factory default u/p.

        curl -s -i -f -u $COUCHBASE_USER:$COUCHBASE_PASS \
            -d "hostname=${IP_PRIVATE}&user=admin&password=password" \
            "http://$CLUSTERIP:8091/controller/addNode"

        if [ $? -eq 0 ]
        then
            let COUCHBASERESPONSIVE=1
        else
            sleep .7
        fi
    done

    echo
    echo '#'
    echo '# Rebalancing cluster'
    echo '#'

    # doing this in a loop in case multiple containers are started at once
    # it seems the rebalance command cannot be called while a rebalance is in progress
    COUCHBASERESPONSIVE=0
    while [ $COUCHBASERESPONSIVE != 1 ]; do
        echo -n '.'

        couchbase-cli rebalance -c 127.0.0.1:8091 -u $COUCHBASE_USER -p $COUCHBASE_PASS
        if [ $? -eq 0 ]
        then
            let COUCHBASERESPONSIVE=1
        else
            sleep .7
        fi
    done
fi


echo
echo '#'
echo '# Confirming cluster health...'
echo '#'

COUCHBASERESPONSIVE=0
while [ $COUCHBASERESPONSIVE != 1 ]; do
    echo -n '.'

    couchbase-cli server-list -c 127.0.0.1:8091 -u $COUCHBASE_USER -p $COUCHBASE_PASS
    if [ $? -eq 0 ]
    then
        let COUCHBASERESPONSIVE=1
    else
        sleep .7
    fi

    # if this never exits, then it will never register as a healthy node in the cluster
    # watch the logs for that...
done

echo
echo '#'
echo '# Register the configured Couchbase instance'
echo '#'

curl -f --retry 7 --retry-delay 3 $CONSUL_HOST/v1/agent/service/register -d "$(printf '{"ID": "%s-%s","Name": "%s","tags": ["couchbase","demo"],"Address": "%s","checks": [{"http": "http://%s:8091/index.html","interval": "13s","timeout": "1s"}]}' $COUCHBASE_SERVICE_NAME $HOSTNAME $COUCHBASE_SERVICE_NAME $IP_PRIVATE $IP_PRIVATE)"

installed