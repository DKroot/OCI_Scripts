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

    $SCRIPT_NAME_WITH_EXT [-n] host_user
    $SCRIPT_NAME_WITH_EXT -p forwarded_host_port
    $SCRIPT_NAME_WITH_EXT -h: display this help

DESCRIPTION
    The following options are available:

    host_user
      * Create a session on the bastion for the OCI host with the maximum possible duration (3 h.)

      * Configure (add or update) host-specific \`ProxyJump\` directive parameter in the SSH config, which enables
      SSH/SFTP in all clients for the session duration.

      * ssh as the specified user (unless -n is specified).

    -n                      configure everything, but do not ssh

    -p forwarded_host_port  create a port-forwarding tunnel from the localhost port to the same port on an OCI bastion,
                            then the OCI host. The tunnel process would run until the session expires or the process is
                            terminated by the user.

ENVIRONMENT

    * OCI CLI is required to be installed.

    * \`jq\` is required to be installed.

    * Required environment variables:
      * \`OCI_INSTANCE\`, Internal FQDN or Private IP e.g., \`kharkiv.subxxx.main.oraclevcn.com\`
      * \`OCI_INSTANCE_OCID\`, e.g., \`ocid1.instance.oc1.iad.xx\`
      * \`OCI_BASTION_OCID\`, e.g., \`ocid1.bastion.oc1.iad.xx\`

    * One of the following SSH public keys in \`~/.ssh/\`: \`id_rsa.pub\`, \`id_dsa.pub\`, \`id_ecdsa.pub\`,
      \`id_ed25519.pub\`, or \`id_xmss.pub\`. If there are multiple keys the first one found in this order will be used.

    Limitations for the \`host_user\` mode:
      1. There is only one OCI bastion session proxy jump host that is being configured in the SSH config.
      2. The OCI host is not yet configured in the SSH config before the first run of this script.

v1.2.0                                        April 2023                                       Created by Dima Korobskiy
Credits: George Chacko, Oracle
HEREDOC
  exit 1
}

########################################################################################################################
# Update or insert a property value in a file. The inserted line could be appended or prepended.
#
# Arguments:
#   $1     file
#   $2     key: an ERE expression. It is matched as a line substring.
#          When key = `^` no matching is done, and the replacement line is *prepended*.
#   $3     (optional) property value line. All matching lines get replaced with this. Defaults to key.
#
# Returns:
#   None
#
# Examples:
#   upsert /etc/ssh/sshd_config 'IgnoreRhosts ' 'IgnoreRhosts yes'
#   upsert /etc/ssh/sshd_config '#*Banner ' 'Banner /etc/issue.net'
#   upsert /etc/logrotate.d/syslog ^ /var/log/cron
#   upsert ~/.ssh/config "Host ${OCI_INSTANCE}"
#
# Author: Dima Korobskiy
# Credits: https://superuser.com/questions/590630/sed-how-to-replace-line-if-found-or-append-to-end-of-file-if-not-found
########################################################################################################################
upsert() {
  local file="$1"
  # Escape all `/` as `\/`
  local -r key="${2//\//\/}"
  local value="${3:-$2}"
  if [[ $3 ]]; then
    echo "\`${file}\` / \`${key}\` := \`${value}\`"
  else
    echo "\`${file}\` << \`${key}\`"
  fi

  if [[ -s "$file" ]]; then
    # Escape all `/` as `\/`
    value="${value//\//\/}"

    case $OSTYPE in
      darwin*) local sed_options=(-I '' -E) ;;
      linux*) local sed_options=(--in-place --regexp-extended) ;;
    esac

    if [[ "$key" == "^" ]]; then
      # no matching is done and the replacement line is *prepended*

      sed "${sed_options[@]}" "1i${value}" "$file"
    else
      # For each matching line (`/.../`), copy it to the hold space (`h`) then substitute the whole line with the
      # `value` (`s`). If the `key` is anchored (`^prefix`), the key line is still matched via `^.*${key}.*`: the second
      # anchor gets ignored.
      #
      # On the last line (`$`): exchange (`x`) hold space and pattern space then check if the latter is empty. If it's
      # empty, that means no match was found so replace the pattern space with the desired value (`s`) then append
      # (`H`) to the current line in the hold buffer. If it's not empty, it means the substitution was already made.
      #
      # Finally, exchange again (`x`).
      sed "${sed_options[@]}" "/${key}/{
          h
          s/^.*${key}.*/${value}/
        }
        \${
          x
          /^\$/{
            s//${value}/
            H
          }
          x
        }" "$file"
    fi
  else
    # No file or empty file
    echo -e "$value" >"$file"
  fi
}

#declare -a ports
# If a character is followed by a colon, the option is expected to have an argument
while getopts p:nh OPT; do
  case "$OPT" in
    p)
      port="$OPTARG"
      #ports+=("$OPTARG")
      ;;
    n)
      readonly SKIP_SSH=true
      ;;
    *) # -h or `?`: an unknown option
      usage
      ;;
  esac
done
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

for required_env_var in 'OCI_INSTANCE' 'OCI_INSTANCE_OCID' 'OCI_BASTION_OCID'; do
  if [[ ! ${!required_env_var} ]]; then
    echo >&2 "Please define $required_env_var"
    exit 1
  fi
done

# `${USER:-${USERNAME:-${LOGNAME}}}` might not be available inside Docker containers
echo -e "\n# oci-bastion.sh: running under $(whoami)@${HOSTNAME} in ${PWD} #"

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
  session_ocid=$(time oci bastion session create-port-forwarding --bastion-id "$OCI_BASTION_OCID" \
    --target-resource-id "$OCI_INSTANCE_OCID" --target-private-ip "${OCI_INSTANCE}" --target-port "$port" \
    --session-ttl $MAX_TTL --ssh-public-key-file $SSH_PUB_KEY --wait-for-state SUCCEEDED --wait-for-state FAILED \
    --wait-interval-seconds $CHECK_INTERVAL_SEC | jq --raw-output '.data.resources[0].identifier')
  echo "Bastion Port Forwarding Session OCID=$session_ocid"
  ssh_command=$(oci bastion session get --session-id "$session_ocid" | jq --raw-output '.data["ssh-metadata"].command')
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
  echo -e "\nCreating a bastion session: this can take up to 1m:20s to succeed..."
  # `--session-ttl`: session duration in seconds (defaults to 30 minutes, maximum is 3 hours).
  # `--wait-interval-seconds`: state check interval (defaults to 30 seconds).
  # `--ssh-public-key-file` is required
  session_ocid=$(time oci bastion session create-managed-ssh --bastion-id "$OCI_BASTION_OCID" \
    --target-resource-id "$OCI_INSTANCE_OCID" --target-os-username "$HOST_USER" --session-ttl $MAX_TTL \
    --ssh-public-key-file $SSH_PUB_KEY --wait-for-state SUCCEEDED --wait-for-state FAILED \
    --wait-interval-seconds $CHECK_INTERVAL_SEC | jq --raw-output '.data.resources[0].identifier')
  echo "Bastion Session OCID=$session_ocid"
  ssh_command=$(oci bastion session get --session-id "$session_ocid" | jq --raw-output '.data["ssh-metadata"].command')
  # Result: `ssh -i <privateKey> -o ProxyCommand=\"ssh -i <privateKey> -W %h:%p -p 22
  #   ocid1.bastionsession.xx@yy.oraclecloud.com\" -p 22 {HOST_USER}@{HOST_IP}`
  # Extract the bastion session SSH destination: the `ocid1.bastionsession.xx@yy.oraclecloud.com` part
  # Remove the string head
  bastion_session_dest=${ssh_command#*ocid1.bastionsession.}
  # Remove the string tail and reconstruct `ocid1.bastionsession.xx@yy.oraclecloud.com`
  bastion_session_dest="ocid1.bastionsession.${bastion_session_dest%%oraclecloud.com*}oraclecloud.com"

  upsert ~/.ssh/config "Host ${OCI_INSTANCE}"
  upsert ~/.ssh/config '  ProxyJump ocid1.bastionsession.' "  ProxyJump ${bastion_session_dest}"

  if [[ $SKIP_SSH ]]; then
    exit 0
  fi
  sleep $AFTER_SESSION_CREATION_WAIT

  echo -e "\nSSH to the target instance via a jump host"
  set -x
  ssh "${HOST_USER}@${OCI_INSTANCE}"
  set +x
fi
