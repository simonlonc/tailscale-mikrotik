# Tailscale for Mikrotik Container

This project provides build and configuration information to run [Tailscale](https://tailscale.com) in [Mikrotik Container](https://help.mikrotik.com/docs/display/ROS/Container). Container is Mikrotik's own implementation of Docker(TM), allowing users to run containerized environments within RouterOS.

This project is only recommended for research and testing purposes. Note the container can impact router performance: running a IPerf test of 50 Mbps via the container on a Mikrotik hAP ax3 consumes ~30% of the router's CPU.

The instructions below assume a use case for tailscale-enabled hosts accessing a router connected LAN subnet. Both Tailscale and Headscale control servers are supported.

Other site to site scenarios are outlined in the [project wiki](https://github.com/Fluent-networks/tailscale-mikrotik/wiki).

## Minimal image

The image is built to fit routers with small internal flash such as the hAP ax2: the arm64 image is about **4.4 MB** (the image tar and the extracted container are both that size).

* `tailscale` and `tailscaled` are a single binary (`tailscale` is a symlink), built with every Tailscale feature a subnet router / exit node does not need compiled out, then packed with UPX (LZMA).
* There is no Alpine, bash, OpenSSH, curl, jq or iproute2. The image is `FROM scratch` with a small static [busybox](busybox.fragment) (`sh`, `ip`, `sysctl`, `vi`, `ping`, `wget`, ...) and a static `iptables-legacy`.
* CA root certificates are embedded in the binary instead of shipping `/etc/ssl`.

Kept features: subnet routes (`--advertise-routes`), exit node (`--advertise-exit-node`), `--accept-routes`, MagicDNS, direct (NAT traversal) connections, OAuth client secrets as `AUTH_KEY`, iptables firewall/SNAT. Compiled out include Tailscale SSH, Taildrop, Serve/Funnel, using an exit node (`--exit-node`), UPnP/NAT-PMP port mapping, Tailnet Lock and `tailscale update`. To add any of them back, append its name to `TS_FEATURES` in the [Dockerfile](Dockerfile) (`go run ./cmd/featuretags --list` in the tailscale source lists them all); each adds some size.

## Requirements

The Mikrotik Container package is compatible with ARM, ARM64 and x86 architectures and the router must be be running RouterOS v7.6 or later. Refer to the [Mikrotik Container documentation](https://help.mikrotik.com/docs/display/ROS/Container) for recommendations, disclaimer and security risks. 

## Instructions

The example container runs as a [tailscale subnet router](https://tailscale.com/kb/1019/subnets/) on a Mikrotik hAP ac3. There are two subnets configured:

* 192.168.88.0/24: the default bridge with physical LAN interface ports, routed to the tailscale network
* 172.17.0.0/16: the docker bridge with a virtual ethernet (veth) interface port for the container

A WAN interface is configured as per default configuration on **ether1** for connectivity to the Tailscale Network. 

Note storage of the docker image on the router uses a USB drive mounted as **disk1** due to the limited storage available on router. To configure storage devices see the [Mikrotik Disks guide](https://help.mikrotik.com/docs/display/ROS/Disks).

### Build the Docker Image

**Note**: this step is only required if you are uploading a tar image file to your router as per Configuration Step 6b.

The build script uses [Docker Buildx](https://docs.docker.com/buildx/working-with-buildx/). Tailscale is cloned and cross-compiled inside the build, so no local Go or tailscale checkout is needed; busybox and iptables are compiled for the target platform, so the builder needs to run (or emulate) it, as before.

1. In `build.sh` set the PLATFORM shell script variable as required for the target router CPU - see [https://mikrotik.com/products/matrix](https://mikrotik.com/products/matrix)

2. Run `./build.sh` to build the image. The build process will generate a container image archive file **`tailscale.tar`**

### Configure the Router

This section follows the Mikrotik Container documentation with additional steps to route the LAN subnet via the tailscale container.


1. Enable container mode, and reboot.

```
/system/device-mode/update container=yes
```

2. Create a veth interface for the container.

```
/interface/veth add name=veth1 address=172.17.0.2/16 gateway=172.17.0.1
```

3. Create a bridge for the container and add veth1 as a port.

```
/interface/bridge add name=dockers
/ip/address add address=172.17.0.1/16 interface=dockers
/interface/bridge/port add bridge=dockers interface=veth1
```

4. Enable routing from the LAN to the Tailscale Network 

```
/ip/route/add dst-address=100.64.0.0/10 gateway=172.17.0.2
```

5. Add environment variables and container mount

| Variable          | Description                                   | Comment                                      |
| ----------------- | --------------------------------------------- | -------------------------------------------- |
| PASSWORD          | Not used: the minimal image has no SSH server  | Use `/container/shell` on the router         |
| AUTH_KEY          | Tailscale non-reusable key, [Oauth secret](https://tailscale.com/kb/1215/oauth-clients#registering-new-nodes-using-oauth-credentials) or Headscale pre-authenticated key                       | Generate from the Tailscale console or Headscale CLI         |
| ADVERTISE_ROUTES  | Comma-separated list of routes to advertise   |                                              |
| CONTAINER_GATEWAY | The container bridge (veth1) IP address on the router |                                              |
| LOGIN_SERVER      | Headscale login server                        | Only required for Headscale control server. Do not set if using Tailscale       |
| UPDATE_TAILSCALE      | Not used: update by building or pulling a newer image          |       |
| TAILSCALE_ARGS    | Additional arguments passed to tailscale      | Optional. Note:<br/> ```--accept-routes``` is required to accept the advertised routes of the other subnet routers.<br/> ```--netfilter-mode``` controls the degree of firewall configuration using iptables. See [tailscale up](https://tailscale.com/kb/1241/tailscale-up). |
| TAILSCALED_ARGS   | Additional arguments passed to tailscaled     | Optional                                     |
| STARTUP_SCRIPT    | Extra script to execute in container before tailscaled | Optional |
| RUNNING_SCRIPT    | Extra script to execute in container after tailscaled is running | Optional |

Example Tailscale control server configuration:
```
/container/envs
add list="tailscale" key="AUTH_KEY" value="tskey-xxxxxxxxxxxxxxxxxxxxxxxx"
add list="tailscale" key="ADVERTISE_ROUTES" value="192.168.88.0/24"
add list="tailscale" key="CONTAINER_GATEWAY" value="172.17.0.1"
add list="tailscale" key="TAILSCALE_ARGS" value="--accept-routes --advertise-exit-node"
```
Example Headscale control server configuration:
```
/container/envs
add list="tailscale" key="AUTH_KEY" value="xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
add list="tailscale" key="ADVERTISE_ROUTES" value="192.168.88.0/24"
add list="tailscale" key="CONTAINER_GATEWAY" value="172.17.0.1"
add list="tailscale" key="LOGIN_SERVER" value="http://headscale.example.com:8080"
add list="tailscale" key="TAILSCALE_ARGS" value="--accept-routes --advertise-exit-node"
```

Define the the mount as per below.

```
/container mounts
add name="tailscale" src="/tailscale" dst="/var/lib/tailscale" 
```

It's possible to execute extra scripts during container startup. To do this, firstly make sure that script(s) are accessible inside
container, for example in `/var/lib/tailscale` folder. 

Scripts are run with busybox `sh` (ash with bash-compatible extensions such as `[[ ]]`; there are no bash arrays).

Then add `STARTUP_SCRIPT` and/or `RUNNING_SCRIPT` environment variables:

```
/container/envs
add list="tailscale" key="STARTUP_SCRIPT" value="/var/lib/tailscale/startup.sh"
add list="tailscale" key="RUNNING_SCRIPT" value="/var/lib/tailscale/running.sh"
```

6. Create the container

The container can be created via the container registry (Step 6a) or using the `tailscale.tar` file generated by building the Docker image locally (Step 6b or 6c).

6a. Container registry

Configure the registry URL and add the container.

```
/container/config 
set registry-url=https://ghcr.io tmpdir=disk1/pull

/container add remote-image=fluent-networks/tailscale-mikrotik:latest interface=veth1 envlist=tailscale cmd=/usr/local/bin/tailscale.sh root-dir=disk1/containers/tailscale mounts=tailscale start-on-boot=yes hostname=mikrotik dns=8.8.4.4,8.8.8.8
```

6b. Tar archive file

Using the file `tailscale.tar` generated by running `build.sh`, upload the file to your router. Below we  assume the image has been uploaded to the router as `disk1/tailscale.tar`

```
/container add file=disk1/tailscale.tar interface=veth1 envlist=tailscale cmd=/usr/local/bin/tailscale.sh root-dir=disk1/containers/tailscale mounts=tailscale start-on-boot=yes hostname=mikrotik dns=8.8.4.4,8.8.8.8
```
Note the **cmd** parameter is required for RouterOS 7.22+

If you want to see the container output in the router log add `logging=yes` to the container add command. 

6c. Tar archive file (routers without external storage)

For routers without USB port (tested on hAP ax2) it's possible to use ramdisk to temporary store `tailscale.tar` file.

Firstly make sure that there is no old version of container installed. Firstly create `tmpfs` disk:

```
/disk add type=tmpfs tmpfs-max-size=10M
```
Upload `tailscale.tar` file to `tmp1/` disk (or move it after uploading to root folder)

Then start container like in 6b:

```
/container add file=tmp1/tailscale.tar interface=veth1 envlist=tailscale cmd=/usr/local/bin/tailscale.sh root-dir=containers/tailscale mounts=tailscale start-on-boot=yes hostname=mikrotik dns=8.8.4.4,8.8.8.8
```

Router will unpack tarball to internal storage. Once container is created it's ok to remove tarball from `tmpfs`. Also,
container will be preserved after router reboot.

### Start the Container

Ensure the container has been extracted and added using `/container/print`. The start the container using

```
/container/start 0
```

### Verify Connectivity

In the Tailscale console, check the router is authenticated and enable the subnet routes. Your tailscale hosts should now be able to reach the router's LAN subnet. 

The minimal image has no SSH server. Access the container via the router CLI:

```
/container/shell 0
mikrotik/# 
```

## Upgrading

### Via Update Command
Stop and then update the container.

```
/container/stop 0
/container/update 0
```

### Via Script
See the **upgrade.rsc** script. To use the script, edit the *hostname* variable to match your container
and import the script - note the script assumes the container repository is being used.

```
/system script add name=upgrade source=[ /file get upgrade.rsc contents];
```

Run the script:
```
/system script 
run [find name="upgrade"];

Stopping the container...
Waiting for the container to stop...
Waiting for the container to stop...
Waiting for the container to stop...
Stopped.
Removing the container...
Waiting for the container to be removed...
Removed.
Adding the container...
Waiting for the container to be added...
Waiting for the container to be added...
Waiting for the container to be added...
Waiting for the container to be added...
Waiting for the container to be added...
Waiting for the container to be added...
Added.
Starting the container.
```

Note the script will continue to run if you are connecting over the tailnet. When completed, check the router is authenticated and enable the subnet routes in the Tailscale console.

## Contributing

We welcome suggestions and feedback from people interested in integrating Tailscale on the RouterOS platform. Please send a PR or create an issue if you're having any problems.