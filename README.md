# Miscellaneous Oracle Cloud Infrastructure (OCI) scripts 

## `ssh-oci-bastion.sh` ##

Configure and ssh or create a tunnel to an Oracle Cloud Infrastructure host via the bastion.


### Setup ###

0. Bash shell, SSH CLI client, `sed`, `sleep`, etc.
    * (macOS, Linux) Out-of-the-box 
    * (Windows) Install [WSL](https://learn.microsoft.com/en-us/windows/wsl/) or [Cygwin](https://www.cygwin.com/)
1. `ssh` CLI client.
    * Generate an SSH key pair if you don't have any. One of the following SSH public keys in \`~/.ssh/\` is required: 
    \`id_rsa.pub\`, \`id_dsa.pub\`, \`id_ecdsa.pub\`, \`id_ed25519.pub\`, or \`id_xmss.pub\`. If there are multiple keys
    the first one found in this order will be used. The corresponding private key is usually also present there, but it
    can be moved to a credential vault and SSH agent, e.g. [1Password](https://developer.1password.com/docs/ssh).     
2. Install and configure [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm).
3. Install [`jq`](https://stedolan.github.io/jq/).
4. Define the following environment variables. OCI menus below are as of October 2022. 
    1. `OCI_INSTANCE`: OCI host Internal FQDN or Private IP. See `Compute` > `Instances` > {host} > `Primary VNIC`.
    2. `OCI_INSTANCE_OCID`. See `Compute` > `Instances` > {host} > `General information` > `OCID`
    3. `OCI_BASTION_OCID`. See `Identity & Security` > `Bastion` > {bastion} > `Bastion information` > `OCID`
    * If you're working with the single OCI host, setting them globally in your environment will work well.
    * If you're working with multiple hosts, you can pass these vars on-the-fly: see the `Usage Examples` section.

### Usage Examples ###

* Create a bastion session and ssh using system environment vars: `ssh-oci-bastion.sh joe`
* Create a bastion session and ssh: 
  `OCI_INSTANCE=10.0.xx OCI_INSTANCE_OCID=ocid1.instance.xx OCI_BASTION_OCID=ocid1.bastion.xx ssh-oci-bastion.sh joe`
* Create a bastion port-forwarding session and launch the tunnel for the port 1234: `ssh-oci-bastion.sh -p 1234` 

