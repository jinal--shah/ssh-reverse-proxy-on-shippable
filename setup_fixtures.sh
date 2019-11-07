#!/usr/bin/env bash
# vim: et sr sw=4 ts=4 smartindent:

# ========================================================================
# CAVEATS
# ========================================================================
# The script contains a bunch of hacks to account for limitations
# of our CI/CD and also quirks of running ssh clients against
# sshd containers on a mac.
#
# Our CI/CD does not support running the builder on a custom
# bridge network.
#
# The CI/CD does support using --link but the docker team
# have deprecated that option so we won't use it.
#
# On a mac, ssh clients do not work well against an ssh server
# exposed via a custom docker bridge network but work fine against
# that same service exposed via the host network ¯\_(ツ)_/¯
#
# Therefore this script assumes:
# 1. If someone runs this script locally it is not within a container.
# 2. The CI/CD building container that runs this script is on the
#    host network.
# 3. a) On a mac, to avoid client issues, sshd access is via localhost.
#    b) In all other cases, we will access the sshd container via the
#       port exposed on the host.
# 4. We do not directly access the web endpoint container.

### GLOBALS
# REQUIRED_VARS can be sourced locally from a .env file.
# To avoid null vals, do not put in this section any  globals
# that rely on any of the REQUIRED_VARS.
REQUIRED_VARS="
    CON_WEB_SERVER_PREFIX
    CON_SSHD_SERVER_PREFIX
    FIXTURES_NET            `# docker bridge network`

    IMG_CURL
    IMG_WEB_SERVER
    IMG_SSHD_SERVER

    TS                      `# timestamp`
"

SSHD_ADDR="" # ... will be defined after container started
SSHD_PORT="" # ... will be defined after container started

TS="$(date +'%Y%m%d%H%M%S')"

CURL_OPTS=(
    -sS                `# ... silent`
    -o /dev/null       `# ... no body output`
    --retry 5          `# ... retry limit`
    --max-time 3       `# ... timeout limit`
    -I                 `# ... return after first response header`
    -w "%{http_code}"  `# ... only print response code`
)

SSH_OPTS=(
    -i ./id_rsa
    -o "UserKnownHostsFile=/dev/null"
    -o "StrictHostKeyChecking=no"
)

check_bash_version() {
    [[ ${BASH_VERSINFO[0]} -ge 5 ]] && return 0
    [[ ${BASH_VERSINFO[0]} -eq 4 ]] && [[ ${BASH_VERSINFO[1]} -ge 3 ]] && return 0

    echo >&2 "ERROR: requires bash >= 4.3.x"
    return 1
}

# We have different logic to navigate docker networks
# on linux to that used on MacOS.
os::is_mac() { [[ "$(uname -s)" =~ [dD]arwin ]] ; }

required_vars() {
    local rc=0
    local required_vars="$1"
    local this_var=""
    for this_var in $required_vars; do
        if ! check_var_defined $this_var
        then
            failed="${failed}\$$this_var "
            rc=1
        fi
    done
    [[ $rc -ne 0 ]] && echo >&2 -e "following vars must be set in env:\n$failed"
    return $rc
}

check_var_defined() { [[ ! -z "${!1}" ]] ; }

pull_imgs() {
    local imgs="$1"
    for img in $imgs; do docker pull $img ; done
}

fixtures_net() {
    if ! docker network inspect $FIXTURES_NET
    then
        docker network create $FIXTURES_NET || return 1
    fi

    return 0
}

web_server::up() {
    docker run -d \
        --name $CON_WEB_SERVER \
        --net $FIXTURES_NET \
            $IMG_WEB_SERVER

    echo "Validating web server ..."
    web_server::verify
}

web_server::verify() {
    if [[ "$(web_server::verify::cmd)" == "200" ]] ; then
        return 0
    else
        echo >&2 "FAILED verifying web server endpoint ..."
        return 1
    fi
}

web_server::verify::cmd() {
    # ... run from same net as webserver container so
    # can refer to it by container name.
    docker run --rm -t \
        --net $FIXTURES_NET \
            $IMG_CURL ${CURL_OPTS[@]} http://$CON_WEB_SERVER
}

sshd_server::up() {
    docker run -d \
        --name $CON_SSHD_SERVER \
        -p 0:22 `# ... needed so we can access this from MacOS` \
        --net $FIXTURES_NET \
            $IMG_SSHD_SERVER

    # Differs if running containers on a mac as docker networking
    # impl on that OS affects ssh clients. See CAVEATS.
    SSHD_ADDR=$(sshd_server::addr) || return 1
    SSHD_PORT=$(sshd_server::port) || return 1

    echo "Validating sshd server $SSHD_ADDR:$SSHD_PORT ..."
    sshd_server::verify
}

sshd_server::verify() {
    if [[ "$(sshd_server::verify::cmd)" == "1" ]]; then
        return 0
    else
        echo >&2 "FAILED verifying sshd endpoint ..."
        return 1
    fi
}

sshd_server::verify::cmd() {

    local ip_sshd_server=""
    local port_sshd_server="22"

    required_vars "SSHD_ADDR SSHD_PORT"

    ssh ${SSH_OPTS[@]} \
        -p $SSHD_PORT \
            root@$SSHD_ADDR pgrep -f /usr/sbin/sshd
}

sshd_server::addr() {
    if os::is_mac
    then
        echo "localhost"
    else
        if ! docker inspect -f "{{$IP_INSPECT_PATH}}" $CON_SSHD_SERVER
        then
            echo >&2 "ERROR: could not get bridge network container ip for $CON_SSHD_SERVER"
            return 1
        fi
    fi
}

sshd_server::port() {
    if os::is_mac
    then
        if ! exposed_port $CON_SSHD_SERVER '22/tcp'
        then
            echo >&2 "ERROR: could not get exposed port of $CON_SSHD_SERVER"
            return 1
        fi
    else
        echo "22"
    fi
}

exposed_port() {
    local con="$1" # container name
    local port_proto="$2"
    (
        set -o pipefail
        o=$(docker port $con $port_proto | awk -F: {'print $NF'} || exit 1)
        if ! [[ "$o" =~ ^[1-9][0-9]+$ ]]; then
            echo >&2 "ERROR - invalid port: $o";
            exit 1
        fi

        echo "$o"
    )
}

# ... tries 3 times.
net::find_free_port() {
    local addr="${1:-127.0.0.1}"
    local max_tries=${2:-3}
    local p="" rc=0

    tries=0
    while true; do
        p=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
        ! net::port_in_use "$addr" "$p" && echo "$p" && break
        (( tries++ )) ; [[ $tries -eq $max_tries ]] && rc=1 && break
    done

    if [[ $rc -ne 0 ]]; then
        echo >&2 "ERROR: failed $max_tries attempts to find free port"
    fi

    return $rc
}

net::port_in_use() {
    local addr="$1"
    local port="$2"
    nc -z $addr $port < /dev/null &>/dev/null
}

ssh_tunnel::test() { 
    local lport=""
    lport=$(net::find_free_port "localhost" 5) || return 1

    ssh_tunnel::up $lport || return 1

    ssh_tunnel::verify $lport
}

ssh_tunnel::up() {
    local lport="$1"

    ssh ${SSH_OPTS[@]} \
        -o ExitOnForwardFailure=yes \
        -f -N -T -M \
        -p $SSHD_PORT \
        -L $lport:$CON_WEB_SERVER:80 \
        root@$SSHD_ADDR sh -c 'while true; do sleep 1 ; done'

    if [[ $? -ne 0 ]]; then
        echo >&2 "ERROR: ssh_tunnel::up failed" &
        return 1
    else
        return 0
    fi
}

ssh_tunnel::verify() {
    local lport="$1"
    resp_code=$(curl ${CURL_OPTS[@]} http://localhost:$lport/)
    if [[ "$resp_code" == "200" ]] ; then
        return 0
    else
        echo >&2 "FAILED verifying web server endpoint ..."
        return 1
    fi
}

cleanup() {
    docker rm -f $CON_WEB_SERVER &>/dev/null
    docker rm -f $CON_SSHD_SERVER &>/dev/null
    # ... ssh tunnel cleaned up as long as sshd container is downed.
}

main() {
    echo "Checking required env vars set ..."
    required_vars "$REQUIRED_VARS" || return 1

    echo "Updating required docker images ..."
    pull_imgs "$IMG_CURL $IMG_WEB_SERVER $IMG_SSHD_SERVER" &>/dev/null

    echo "Creating network $FIXTURES_NET if needed ..."
    fixtures_net &>/dev/null || return 1

    echo "Creating web server ..."
    web_server::up || return 1

    echo "Creating sshd server ..."
    sshd_server::up || return 1

    echo "Testing ssh tunnel"
    ssh_tunnel::test || return 1

    return 0
}

cleanup_all() {
    cleanup
    docker rm -f $CON_WEB_SERVER &>/dev/null
    docker rm -f $CON_SSHD_SERVER &>/dev/null
}

cleanup() {
    pkill -f "ssh .*$CON_WEB_SERVER" &>/dev/null || return 1
}

check_bash_version || return 1

# For dev convenience we honour any custom .env file
# Yes. All the devs are mac fan boys.
os::is_mac && [[ -r "./.env" ]] && . .env # devs can override stuff in .env

# ... docker infra names
IP_INSPECT_PATH=".NetworkSettings.Networks.${FIXTURES_NET}.IPAddress"
CON_WEB_SERVER="${CON_WEB_SERVER_PREFIX}_${TS}"
CON_SSHD_SERVER="${CON_SSHD_SERVER_PREFIX}_${TS}"

cat << EOF
$(os::is_mac && echo "... running on mac")
 CON_WEB_SERVER: $CON_WEB_SERVER
CON_SSHD_SERVER: $CON_SSHD_SERVER
EOF

 main ; rc=$? ; 

# if [[ $rc -ne 0 ]]; then cleanup_all ; else cleanup ; fi `# for use in test runner`
cleanup_all ;

exit $rc

