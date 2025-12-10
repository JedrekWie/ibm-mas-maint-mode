#/bin/bash

die () {
    echo >&2 "$@"
    exit 1
}

# Validate arguments count
# argDie <expected> <actual> <hint>
argDie () {
    [ "$1" -eq "$2" ] || die "$1 argument(-s) required, $2 provided. $3"
}

# Validate minimal arguments count
# argMinDie <expected> <miminal> <hint>
argMinDie () {
    [ "$1" -le "$2" ] || die "At least $1 argument(-s) required, $2 provided. $3"
}

# Validate environment
envDie () {
    echo $1 | grep -E -i -q '^(dev|test|prod)$' \
        || die "Environment name expected (DEV, TEST or PROD), $1 provided"

    export ENVU=$(echo $1 | tr '[:lower:]' '[:upper:]')
    export ENVL=$(echo $1 | tr '[:upper:]' '[:lower:]')
}

# Validate if value is present
# valueDie <name> <value>
valueDie () {
    argDie 2 $# "Check if ${1:-[unknown]} value is set."
    [ "$2" != "" ] || die "Required $1 variable value is missing."
}

# Validate whether podman command is available
podmanDie () {
    command -v podman 2>&1 >/dev/null || die "Podman not available. Run this script from outside of a container."
}

# Validate whether yq command is available
yqDie () {
    command -v yq 2>&1 >/dev/null || die "yq not available. Make sure it is intstalled in your environment."
}

# Confirm operation. 
# Optionally call with a prompt string or use a default
confirm () {
    read -r -p "${1:-Are you sure?} [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            die "Script interrupted."
            ;;
    esac
}

# Returns domain name for given environment
ocDomain () {
    envDie $1
    # FIXME: Update OCP cluster domain evaluation according to 
    # your naming conventions, for example:
    #   SUFFIX=$([ "$ENVL" == "prod" ] || echo "nonprod")
    #   echo "mas$SUFFIX.example.com"
    # This implementation always returns fixed domain name
    # regardless of the current environment
    echo "mas.example.com"
}

# Validate whether oc command is available and user is logged in
ocDie () {
    oc whoami --show-console=true 2>&1 </dev/null >/dev/null \
        || die "oc utility not found or user not logged in."
}

# Depending on the user setup initiates KUBECONFIG variable
# FIXME: Update this function in order to automatically select
# 'kubeconfig' file used for authentication and therefore avoid
# switching authentication contexts running the script against
# different environments (OCP clusters).
# This implementation does nothing effectively always relying
# on current OC CLI authentication context.
ocConfig () {
    # envDie $1
    # SUFFIX=$([ "$ENVL" == "prod" ] || echo "nonprod")
    # local CONFIG=~/.kube/config-mas$SUFFIX
    # [ "$OCCONFIG_SKIP" == "" ] \
    #     && [ -f $CONFIG ] && export KUBECONFIG=$CONFIG \
    #     && [ "$OCCONFIG_PRINTED" == "" ] \
    #     && echo "Using OCP config: $CONFIG" \
    #     && export OCCONFIG_PRINTED=1
    echo
}

# Validate whether requested environment matches OCP cluster.
# Validation can be disabled by setting global variable OCENV_SKIP
ocEnvDie () {
    envDie $1
    ocConfig $1
    OC_DOMAIN=$(ocDomain $1)
    if [ "$OCENV_SKIP" != "" ] ; then
        echo "### WARNING: OCP context validation disabled. Unset OCENV_SKIP variable to enable it."
    else
        CURRENT_OC_DOMAIN=$(oc whoami --show-console=true 2>&1 </dev/null)
        echo $CURRENT_OC_DOMAIN | grep -q $OC_DOMAIN \
            || die "$ENVU environment's domain ($OC_DOMAIN) doesn't match current OCP context ($CURRENT_OC_DOMAIN)."
    fi
}

# Returns the name of the MAS instance in given environment
# FIXME: Update MAS instance name evaluation according to your naming convention
ocMasInstance () {
    envDie $1
    echo $ENVL
}

# Returns namespace of the Core installation in given environment
ocCoreNs () {
    envDie $1
    echo mas-$(ocMasInstance $ENVL)-core
}

# Returns namespace of the Manage installation in given environment
ocManageNs () {
    envDie $1
    echo mas-$(ocMasInstance $ENVL)-manage
}

# List of namespaces which remote access will be redirected to the maintenance page
# FIXME: Currently supported for MAS Core and Manage. Potentially extendable to other MAS compontnes.
ocMasNsList () {
    echo "$(ocCoreNs $ENVL) $(ocManageNs $ENVL)"
}

# Returns namespace of the maintenance mode setup, where deployment and routes are created.
# It's recommended to keep maintenance mode configurations for different environments
# running in the same OCP cluster definced in separate namespaces.
# FIXME: Update result evaluation according to your naming convention
ocMaintNs() {
    envDie $1
    echo maintenance-$(ocMasInstance $ENVL)
}

# Returns name of the deployment handling maintenance mode
# FIXME: Update result evaluation according to your naming convention
# For typical use cases it can be simply fixed value just like below
ocMaintDepl() {
    envDie $1
    echo maintenance
}

# Returns key name of the label indicating maintenance mode
# FIXME: Update result evaluation according to your naming convention
# For typical use cases it can be simply fixed value just like below
ocMaintLblKey() {
    envDie $1
    echo router-mode
}

# Returns value of the label indicating maintenance mode
# FIXME: Update result evaluation according to your naming convention
# For typical use cases it can be simply fixed value just like below
ocMaintLblValue() {
    envDie $1
    echo inactive
}

# Returns the label indicating maintenance mode
ocMaintLbl() {
    envDie $1
    echo "$(ocMaintLblKey $1)=$(ocMaintLblValue $1)"
}

# Retrieves Ingress Controller YAML definition
ocIcYaml () {
    IO_NS=openshift-ingress-operator
    IC_NAME=$1
    oc get -n $IO_NS ingresscontroller $IC_NAME -o yaml
}

# Load common overrides, used for testing
COMMON_OVERRIDES="$(dirname "$0")/common-overrides.sh"
[ -f $COMMON_OVERRIDES ] && . $COMMON_OVERRIDES