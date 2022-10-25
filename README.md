# Miscellaneous Oracle Cloud Infrastructure (OCI) scripts 

## `ssh-oci-bastion.sh` ##

Configure and ssh or create a tunnel to an Oracle Cloud Infrastructure host via the bastion.

### Setup ###

0. Bash shell, SSH CLI client, `sed`, `sleep`, etc.
    * (macOS, Linux) Out-of-the-box 
    * (Windows) Install [WSL](https://learn.microsoft.com/en-us/windows/wsl/) or [Cygwin](https://www.cygwin.com/) 
1. Install [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm).
2. Install [`jq`](https://stedolan.github.io/jq/).
3. Define the following environment variables. OCI menus below are as of October 2022. 
    1. `OCI_INSTANCE_IP`: OCI host IP. See `Compute` > `Instances` > {host} > `Primary VNIC` > `Private IP address`
    2. `OCI_INSTANCE_OCID`. See `Compute` > `Instances` > {host} > `General information` > `OCID`
    3. `OCI_BASTION_OCID`. See `Identity & Security` > `Bastion` > {bastion} > `Bastion information` > `OCID`
    * If you're working with the single OCI host, setting them globally in your environment will work well.
    * If you're working with multiple hosts, you can pass these vars on-the-fly: see the `Usage Examples` section.

### Usage Examples ###

* Create a bastion session and ssh using system environment vars: `ssh-oci-bastion.sh joe`
* Create a bastion session and ssh: 
  `OCI_INSTANCE_IP=10.0.xx OCI_INSTANCE_OCID=ocid1.instance.xx OCI_BASTION_OCID=ocid1.bastion.xx ssh-oci-bastion.sh joe`
* Create a bastion port-forwarding session and launch the tunnel for the port 1234: `ssh-oci-bastion.sh -p 1234` 

