#!/usr/bin/env bash
set -e
set -o pipefail

# Remove the longest `*/` prefix
readonly SCRIPT_NAME_WITH_EXT="${0##*/}"

usage() {
  cat <<HEREDOC
NAME

    $SCRIPT_NAME_WITH_EXT -- configure and ssh or create a tunnel to an Oracle Cloud Infrastructure host via the bastion

SYNOPSIS

    $SCRIPT_NAME_WITH_EXT [-o OCI_profile] [-n] host_user
    $SCRIPT_NAME_WITH_EXT [-o OCI_profile] -p forwarded_host_port
    $SCRIPT_NAME_WITH_EXT -h: display this help

DESCRIPTION
    The following options are available:

    host_user
      * Create a session on the bastion for the OCI host with the maximum possible duration (3 h.)

      * Configure (append or update) host-specific \`ProxyJump\` directive parameter in the SSH config, which enables
      SSH/SFTP in all clients for the session duration.

      * ssh as the specified user (unless -n is specified).

    -n                      configure everything, but do not ssh

    -p forwarded_host_port  create a port-forwarding tunnel from the localhost port to the same port on an OCI bastion,
                            then the OCI host. The tunnel process would run until the session expires or the process is
                            terminated by the user.

    -o OCI_profile          use a specified profile section from the \`~/.oci/config\` file [default: \`DEFAULT\`]

ENVIRONMENT

    * Required commands:
      * OCI CLI
      * \`jq\`
      * \`pcregrep\`
      * \`perl\`

    * Required environment variables:
      * \`OCI_INSTANCE_OCID\`, e.g., \`ocid1.instance.oc1.iad.xx\`
      * \`OCI_BASTION_OCID\`, e.g., \`ocid1.bastion.oc1.iad.xx\`
      * For \`host_user\` SSH sessions only:
        * \`OCI_INSTANCE\`, Internal FQDN or Private IP e.g., \`kharkiv.subxxx.main.oraclevcn.com\`

    * One of the following SSH public keys in \`~/.ssh/\`: \`id_rsa.pub\`, \`id_dsa.pub\`, \`id_ecdsa.pub\`,
      \`id_ed25519.pub\`, or \`id_xmss.pub\`. If there are multiple keys the first one found in this order will be used.

    * If the SSH config has global (\`Host *\`) \`ProxyJump\` parameter it would take precedence.
    Since the first obtained value for each parameter is used, more host-specific declarations should be given near the
    beginning of the file, and general defaults at the end. Prepend the following configuration manually in this case
    before using this script:
    \`\`\`
    Host {target}
      ProxyJump
    \`\`\`

v2.0.3                                         May 2023                                        Created by Dima Korobskiy
Credits: George Chacko, Oracle
HEREDOC
  exit 1
}

#declare -a ports
# If a character is followed by a colon, the option is expected to have an argument
while getopts np:o:h OPT; do
  case "$OPT" in
  n)
    readonly SKIP_SSH=true
    ;;
  p)
    port="$OPTARG"
    #ports+=("$OPTARG")
    ;;
  o)
    readonly PROFILE_OPT="--profile $OPTARG"
    ;;
  *) # -h or `?`: an unknown option
    usage
    ;;
  esac
done
echo -e "\n# \`$0 $*\`: run by \`${USER:-${USERNAME:-${LOGNAME:-UID #$UID}}}@${HOSTNAME}\`, in \`${PWD}\` #\n"
shift $((OPTIND - 1))

# Process positional parameters
readonly HOST_USER=$1

if ! command -v oci >/dev/null; then
  # shellcheck disable=SC2016
  echo >&2 'Please install OCI CLI'
  exit 1
fi

if ! command -v jq >/dev/null; then
  # shellcheck disable=SC2016
  echo >&2 'Please install `jq`'
  exit 1
fi

if ! command -v pcregrep >/dev/null; then
  # shellcheck disable=SC2016
  echo >&2 'Please install PCRE'
  exit 1
fi

if ! command -v perl >/dev/null; then
  echo "Please install Perl"
  exit 1
fi

for required_env_var in 'OCI_INSTANCE' 'OCI_INSTANCE_OCID' 'OCI_BASTION_OCID'; do
  if [[ ! ${!required_env_var} ]]; then
    echo >&2 "Please define $required_env_var"
    exit 1
  fi
done

readonly MAX_TTL=$((3 * 60 * 60))
readonly CHECK_INTERVAL_SEC=5
# Intermittent `Permission denied (publickey)` errors might occur when trying to ssh immediately after session creation
readonly AFTER_SESSION_CREATION_WAIT=10

# Determine which keypair ssh uses by default.
# The default key order as of OpenSSH 8.1p1m (see `ssh -v {destination}`)
for key_type in 'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' 'id_xmss'; do
  pub_key_file=~/.ssh/$key_type.pub
  if [[ -f $pub_key_file ]]; then
    readonly SSH_PUB_KEY=$pub_key_file
    echo "Using $SSH_PUB_KEY as a public key"
    break
  fi
done
if [[ ! $SSH_PUB_KEY ]]; then
  echo >&2 'No SSH public key is found'
  exit 1
fi

if [[ $port ]]; then
  echo -e "\nCreating a port forwarding tunnel for the port $port: this can take up to 20s to succeed ..."
  # `--session-ttl`: session duration in seconds (defaults to 30 minutes, maximum is 3 hours).
  # `--wait-interval-seconds`: state check interval (defaults to 30 seconds).
  # `--ssh-public-key-file` is required
  # `--target-private-ip` "${OCI_INSTANCE}"
  # shellcheck disable=SC2086 # $PROFILE_OPT is a two-word CLI option
  session_ocid=$(time oci bastion session create-port-forwarding $PROFILE_OPT --bastion-id "$OCI_BASTION_OCID" \
    --target-resource-id "$OCI_INSTANCE_OCID" --target-port "$port" \
    --session-ttl $MAX_TTL --ssh-public-key-file $SSH_PUB_KEY --wait-for-state SUCCEEDED --wait-for-state FAILED \
    --wait-interval-seconds $CHECK_INTERVAL_SEC | jq --raw-output '.data.resources[0].identifier')
  echo "Bastion Port Forwarding Session OCID=$session_ocid"

  # shellcheck disable=SC2086 # $PROFILE_OPT is a two-word CLI option
  ssh_command=$(oci bastion session get $PROFILE_OPT --session-id "$session_ocid" |
    jq --raw-output '.data["ssh-metadata"].command')
  # Result: `ssh -i <privateKey> -N -L <localPort>:{HOST_IP}:5432 -p 22 ocid1.bastionsession.xx@yy.oraclecloud.com`
  # Remove the placeholder
  ssh_command="${ssh_command/-i <privateKey>/}"
  # Replace the placeholder
  ssh_command="${ssh_command/<localPort>/localhost:$port}"
  sleep $AFTER_SESSION_CREATION_WAIT

  echo -e "\nLaunching an SSH tunnel"
  set -x
  # This only works assuming there are no internal quotes in the command
  $ssh_command
  set +x
  exit
fi

if [[ $HOST_USER ]]; then
  echo -e "\nCreating a bastion session: this can take up to 1m:30s to succeed..."
  # `--session-ttl`: session duration in seconds (defaults to 30 minutes, maximum is 3 hours).
  # `--wait-interval-seconds`: state check interval (defaults to 30 seconds).
  # `--ssh-public-key-file` is required
  # shellcheck disable=SC2086 # $PROFILE_OPT is a two-word CLI option
  session_ocid=$(time oci bastion session create-managed-ssh $PROFILE_OPT --bastion-id "$OCI_BASTION_OCID" \
    --target-resource-id "$OCI_INSTANCE_OCID" --target-os-username "$HOST_USER" --session-ttl $MAX_TTL \
    --ssh-public-key-file $SSH_PUB_KEY --wait-for-state SUCCEEDED --wait-for-state FAILED \
    --wait-interval-seconds $CHECK_INTERVAL_SEC | jq --raw-output '.data.resources[0].identifier')
  echo "Bastion Session OCID=$session_ocid"

  # shellcheck disable=SC2086 # $PROFILE_OPT is a two-word CLI option
  ssh_command=$(oci bastion session get $PROFILE_OPT --session-id "$session_ocid" |
    jq --raw-output '.data["ssh-metadata"].command')
  # Result: `ssh -i <privateKey> -o ProxyCommand=\"ssh -i <privateKey> -W %h:%p -p 22
  #   ocid1.bastionsession.xx@yy.oraclecloud.com\" -p 22 {HOST_USER}@{HOST_IP}`
  # Extract the bastion session SSH destination: the `ocid1.bastionsession.xx@yy.oraclecloud.com` part
  # Remove the string head
  bastion_session_dest=${ssh_command#*ocid1.bastionsession.}
  # Remove the string tail and reconstruct `ocid1.bastionsession.xx@yy.oraclecloud.com`
  bastion_session_dest="ocid1.bastionsession.${bastion_session_dest%%oraclecloud.com*}oraclecloud.com"

  # Multi-line upsert
  if pcregrep -M -q "(?s)Host ${OCI_INSTANCE}.*?ProxyJump" ~/.ssh/config; then
    # Update

    # -i input edited in-place
    # -p iterate over filename arguments
    # -0 use null as record separator
    # Don't combine these options: the combination might not work
    # `@host` in the bastion session has to be escaped
    perl -i -p -0 -e "s/(Host ${OCI_INSTANCE}.*?)ProxyJump.*?\n/\1ProxyJump ${bastion_session_dest//@/\\@}\n/s" \
      ~/.ssh/config
  else
    # Append
    cat >>~/.ssh/config <<HEREDOC


Host ${OCI_INSTANCE}
  ProxyJump ${bastion_session_dest}
HEREDOC
  fi

  if [[ $SKIP_SSH ]]; then
    exit 0
  fi
  sleep $AFTER_SESSION_CREATION_WAIT

  echo -e "\nSSH to the target instance via a jump host"
  set -x
  ssh "${HOST_USER}@${OCI_INSTANCE}"
  set +x
fi
