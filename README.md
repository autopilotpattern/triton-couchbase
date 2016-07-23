# Autopilot Pattern Couchbase

[![DockerPulls](https://img.shields.io/docker/pulls/autopilotpattern/couchbase.svg)](https://registry.hub.docker.com/u/autopilotpattern/couchbase/)
[![DockerStars](https://img.shields.io/docker/stars/autopilotpattern/couchbase.svg)](https://registry.hub.docker.com/u/autopilotpattern/couchbase/)
[![ImageLayers](https://badge.imagelayers.io/autopilotpattern/couchbase:latest.svg)](https://imagelayers.io/?images=autopilotpattern/couchbase:latest)
[![Join the chat at https://gitter.im/autopilotpattern/general](https://badges.gitter.im/autopilotpattern/general.svg)](https://gitter.im/autopilotpattern/general)

This repo is a demonstration of the [Autopilot Pattern](http://autopilotpattern.io/) as applied to [Couchbase](http://www.couchbase.com/). Couchbase's built-in cluster awareness and automatic management of data, including sharding and cross-datacenter replication make it ideal for deployment as a part of an entire stack using the Autopilot Pattern.

Included here is everything you need to deploy a Couchbase cluster that can be easily scaled just by using `docker-compose scale couchbase=$n`. The repo consists of a Dockerfile to build a Couchbase container image, a couple of shell scripts to setup your environment and assist orchestration, and a Docker Compose file to tie it all together.

### Bootstrapping Couchbase

A new Couchbase node only needs to know where to find one other node in order to join a cluster. In this pattern we're using a ContainerPilot `health` check handler to coordinate the creation of the cluster. We're using [Consul](https://www.consul.io/) as a service discovery layer. Consul is running in its default configuration as delivered in [Jeff Lindsay's excellent image](https://registry.hub.docker.com/u/progrium/consul/), but Couchbase uses a ContainerPilot health check handler to enable the magic [here](https://github.com/autopilotpattern/couchbase/blob/master/bin/manage.sh).

Each time the [`health` handler](https://github.com/autopilotpattern/couchbase/blob/master/bin/manage.sh) runs, it first checks to see if the node has already been joined to a cluster. If so, it continues on to health check the node and then send a heartbeat to Consul. If not, the handler needs to figure out whether the cluster has been initialized. The steps are as follows:

1. Has another node been registered with Consul for the cluster? If so, we can join to it.
1. Is another node in the middle of bootstrapping the cluster? If so, wait for it and then join to it.
1. Otherwise, bootstrap the cluster but let any other nodes know that we're doing it by writing a lock in Consul.

### Setting up with Triton (optional)

1. [Get a Joyent account](https://my.joyent.com/landing/signup/) and [add your SSH key](https://docs.joyent.com/public-cloud/getting-started).
1. Install the [Docker Toolbox](https://docs.docker.com/installation/mac/) (including `docker` and `docker-compose`) on your laptop or other environment, as well as the [Joyent Triton CLI](https://www.joyent.com/blog/introducing-the-triton-command-line-tool) (`triton` replaces our old `sdc-*` CLI tools)
1. [Configure Docker and Docker Compose for use with Joyent](https://docs.joyent.com/public-cloud/api-access/docker):

```bash
curl -O https://raw.githubusercontent.com/joyent/sdc-docker/master/tools/sdc-docker-setup.sh && chmod +x sdc-docker-setup.sh
./sdc-docker-setup.sh -k us-east-1.api.joyent.com <ACCOUNT> ~/.ssh/<PRIVATE_KEY_FILE>
```

### Getting started

Check that everything is configured correctly by running `./setup.sh`. If it returns without an error you're all set. This script will create and `_env` file that includes the Triton CNS name for the Consul service if using Triton. You'll want to edit this file to update the username and password for Couchbase.

### Running the cluster

Once you've cloned the repo and run `./setup.sh`, you can start a new cluster with just Docker Compose:

```bash
$ docker-compose --project-name=cb up -d
Creating cb_consul_1
Creating cb_couchbase_1
```

Because one Couchbase container can get lonely, we can use Docker Compose to give it some friends:

```bash
$ docker-compose -p cb scale couchbase=3
Creating couchbase_couchbase_2
Creating couchbase_couchbase_3

$ docker-compose -p cb ps
Name                   Command                  State                   Ports
-------------------------------------------------------------------------------------
cb_consul_1      /bin/start -server -bootst ...   Up      53/tcp, 53/udp, 8300/tcp...
cb_couchbase_1   /bin/containerpilot /usr/...     Up      11207/tcp, 11210/tcp,
                                                          11211/tcp, 18091/tcp,
                                                          18092/tcp, 8093/tcp,
                                                          0.0.0.0:8091/tcp->8091/tcp,
                                                          0.0.0.0:8092/tcp->8092/tcp,
cb_couchbase_2   /bin/containerpilot /usr/...     Up      11207/tcp, 11210/tcp,
                                                          11211/tcp, 18091/tcp,
                                                          18092/tcp, 8093/tcp,
                                                          0.0.0.0:8091/tcp->8091/tcp,
                                                          0.0.0.0:8092/tcp->8092/tcp,
cb_couchbase_3   /bin/containerpilot /usr/...     Up      11207/tcp, 11210/tcp,
                                                          11211/tcp, 18091/tcp,
                                                          18092/tcp, 8093/tcp,
                                                          0.0.0.0:8091/tcp->8091/tcp,
                                                          0.0.0.0:8092/tcp->8092/tcp,
```

A shell script (`./demo.sh`) has been provided to run these two commands as well as find and open the Couchbase dashboard in your web browser. Sign in with the username and password you provided in the environment file to see the working cluster. As the cluster scales up you'll be able to see node(s) join the cluster.

### Initializing a bucket

Standing up the cluster does not initialize any Couchbase buckets, because these are specific to your application(s). The `./demo.sh` script will create a Couchbase bucket using the Couchbase REST API as an example of what your application's `preStart` handler should do.

### Consul notes

[Bootstrapping](https://www.consul.io/docs/guides/bootstrapping.html), [Consul clusters](https://www.consul.io/intro/getting-started/join.html), and the details about [adding and removing nodes](https://www.consul.io/docs/guides/servers.html). The [CLI](https://www.consul.io/docs/commands/index.html) and [HTTP](https://www.consul.io/docs/agent/http.html) API are also documented.

[Check for registered instances of a named service](https://www.consul.io/docs/agent/http/catalog.html#catalog_service)

```bash
curl -v http://consul:8500/v1/catalog/service/couchbase | json -aH ServiceAddress
```

[Register an instance of a service](https://www.consul.io/docs/agent/http/catalog.html#catalog_register)

```bash
export MYIP=$(ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
curl http://consul:8500/v1/agent/service/register -d "$(printf '{"ID": "couchbase-%s","Name": "couchbase","Address": "%s"}' $MYIP $MYIP)"
```
