#/bin/bash

# Sets up all components required by maintenance mode
# 1. Update default ingress controller
# 2. Setup Project
# 3. Setup Deployment
# 4. Setup alternative routes

SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. $SCRIPT_DIR/common.sh

argDie 1 $# "USAGE: <env>"
ocEnvDie $1

MAINT_NS=$(ocMaintNs $ENVL)
# Name of the deployment handling user requests in maintenance mode
MAINT_DEPL=$(ocMaintDepl $ENVL)
# Key name and value of the label used to tag namespaces in order to indicate
# that they are handled by a maintenance ingress controller
MAINT_LABEL_KEY=$(ocMaintLblKey $ENVL)
MAINT_LABEL_VALUE=$(ocMaintLblValue $ENVL)

# List of namespaces which remote access will be redirected to the maintenance page
MAS_NAMESPACES=$(ocMasNsList $ENVL)

# Update default ingress controller by adding maintenance mode namespace exclusion (if needed)
# Check if 'namespaceSelector' section already exists and if not then create one
ocIcYaml default | KEY=$MAINT_LABEL_KEY yq -e '.spec.namespaceSelector.matchExpressions[] | select(.key == env(KEY))' >/dev/null 2>&1 \
    || {
        echo "Adding 'namespaceSelector' to the default ingress controller..." \
        && ocIcYaml default \
            | KEY=$MAINT_LABEL_KEY VALUE=$MAINT_LABEL_VALUE yq 'with(.spec.namespaceSelector.matchExpressions; 
                    . = [.[] | select(.key != env(KEY))] + { "key": env(KEY), "operator": "NotIn", "values": [ env(VALUE) ] })' \
            | oc apply -f -
    }

# Create project if one doesn't exist yet
oc get project $MAINT_NS >/dev/null 2>&1 \
    || {
        echo "Creating maintenance mode project for $ENVU environment..." \
        && oc new-project $MAINT_NS --display-name="$ENVU Maintenance Mode" >/dev/null 2>&1 \
        && oc label --overwrite namespace $MAINT_NS $(ocMaintLbl $ENVL) >/dev/null
    }

# Create deployment if one doesn't exist yet
oc get deployment -n $MAINT_NS $MAINT_DEPL >/dev/null 2>&1 \
    || {
        echo "Creating maintenance mode deployment for $ENVU environment..." \
        && cat $SCRIPT_DIR/deployment.yaml \
            | NAME=$MAINT_DEPL yq -e '.metadata.name = env(NAME) | (.. | select(has("app")) | .app) = env(NAME) | (.. | select(has("deployment")) | .deployment) = env(NAME)' \
            | oc create -n $MAINT_NS -f - >/dev/null 2>&1 
    }

# Create static landing page
oc get configmap -n $MAINT_NS maintenance-html >/dev/null 2>&1 \
    || {
        echo "Creating maintenance mode landing page for $ENVU environment..." \
        && oc create configmap -n $MAINT_NS maintenance-html --from-file=maintenance.html=$SCRIPT_DIR/maintenance.html >/dev/null
    }

# Generate nginx default server configuration

# Generates nginx config containing trusted proxies/load balancers IP ranges
# Output variable is: TRUSTED_PROXIES
genTrustedProxiesConfig () {
    NETWORK_CIDRS=$(oc get network -o yaml | yq -r '.items[] | ((.status.clusterNetwork[] | .cidr), .status.serviceNetwork[])')
    while read -r NODE_CIDR; do
        TRUSTED_PROXIES+="set_real_ip_from $NODE_CIDR;###"
    done <<< "$NETWORK_CIDRS"
}

getBypassConfigClusterNetworks () {
    BYPASS_CIDRS+="    # Cluster networks ###"
    NETWORK_CIDRS=$(oc get network -o yaml | yq -r '.items[] | ((.status.clusterNetwork[] | .cidr), .status.serviceNetwork[])')
    while read -r NODE_CIDR; do
        BYPASS_CIDRS+="    $NODE_CIDR     1;###"
    done <<< "$NETWORK_CIDRS"
}

# Generates nginx config containing default reverse proxy bypass rules for cross node communication
# Output variable is: BYPASS_CIDRS
genBypassConfigWorkerNodes () {
    BYPASS_CIDRS+="    # Worker nodes ###"
    NODE_ADDRS=$(oc get nodes --selector='node-role.kubernetes.io/worker' -o yaml | \
        yq -r '.items[] | (.status.addresses[] | select(.type == "InternalIP") | .address)')
    while read -r NODE_ADDR; do
        BYPASS_CIDRS+="    $NODE_ADDR    1;###"
    done <<< "$NODE_ADDRS"
}

# Generates nginx config containing default reverse proxy bypass rules for current host
# Output variable is: BYPASS_CIDRS
genBypassConfigSelfHost () {
    # Add bypass rule for current host IP
    CURRENT_IP=$(curl -s ifconfig.me) && [ -n "$CURRENT_IP" ] && {
        BYPASS_CIDRS+="    # Current host: $HOSTNAME\/$USER \[$(date "+%Y-%m-%d %H:%M:%S")\] ###"
        BYPASS_CIDRS+="    $CURRENT_IP    1;###"
    }
}

# Generates nginx config containing default reverse proxy bypass rules for explicitly allowed IPs
# Output variable is: BYPASS_CIDRS
genBypassConfigExplicitIPs () {
    # Load any additional bypass rules from the config file
    BYPASS_LIST=$SCRIPT_DIR/bypass-cidrs.list
    if [ -f $BYPASS_LIST ] ; then
        BYPASS_CIDRS+="    # Additional bypass rules from $(basename $BYPASS_LIST) file ###"
        # Read the file line by line to process each entry.
        while IFS= read -r LINE; do
            # 1. Skip empty or blank lines.
            [ -z "$LINE" ] && continue
            # 2. Skip comments (lines starting with #).
            [[ "$LINE" =~ ^\s*# ]] && continue
            # 3. Add the line to BYPASS_CIDRS variable.
            BYPASS_CIDRS+="    $LINE    1;###"
        done < "$BYPASS_LIST"
    fi
}

# Generates nginx config containing default reverse proxy bypass secret key
# Output variable is: BYPASS_KEY
genBypassConfigKey () {
    # Generate a random secret key for bypassing the maintenance mode
    BYPASS_KEY=${BYPASS_KEY:-$(openssl rand -hex 32)}
    echo "⚠️ Maintenance mode bypass key 🔑: $BYPASS_KEY"
    echo "💡 Use the value printed above to bypass maintenance mode, e.g. when deploying RBA apps from other trusted area."
}

# Generates nginx config containing default reverse proxy bypass rules
# Output variables are: 
# * BYPASS_CIDRS
# * BYPASS_KEY
genBypassConfig () {
    getBypassConfigClusterNetworks
    genBypassConfigWorkerNodes
    genBypassConfigSelfHost
    genBypassConfigExplicitIPs
    genBypassConfigKey
}

# Generates nginx config entries for given namespace
# Output variables are:
# 1. UPSTREAMS - list of target servers
# 2. BACKENDS - list of backends to map
genUpstreamConfig () {
    ROUTES_NS=$1
    # Get more route details in order to sort results.
    # This will affect nginx matching order.
    # Sorting rules:
    # 1. Deeper paths first
    # 2. Then by host alphabetically
    # 3. Finally by path - longer paths first
    ROUTES=$(oc get routes -n $ROUTES_NS --no-headers -o custom-columns=":metadata.name,:spec.host,:spec.path" \
        | awk '
            {
                host_for_count = $2
                path_for_count = $3
                gsub(/[^.]/, "", host_for_count)
                num_dots = length(host_for_count)
                path_len = length(path_for_count)
                print num_dots "\t" $2 "\t" path_len "\t" $0
            }' \
        | sort -t$'\t' -k1,1nr -k2,2 -k3,3nr)
    while IFS= read -r ROUTE; do
        ROUTE_NAME=$(echo "$ROUTE" | awk '{print $4}')
        ROUTE_YAML=$(oc get route -n $ROUTES_NS $ROUTE_NAME -o yaml)
        ROUTE_HOST=$(echo "$ROUTE_YAML" | yq '.spec.host')
        ROUTE_PATH=$(echo "$ROUTE_YAML" | yq '.spec.path')
        ROUTE_SERVICE=$(echo "$ROUTE_YAML" | yq '.spec.to.name')
        ROUTE_PORT_NAME=$(echo "$ROUTE_YAML" | yq '.spec.port.targetPort')
        ROUTE_PORT=$(oc get service -n $ROUTES_NS $ROUTE_SERVICE -o yaml \
            | NAME=$ROUTE_PORT_NAME yq '.spec.ports[] | select(.name == env(NAME)) | .port')
        # Guarantee uniqueness of the upstreams
        [[ $UPSTREAMS =~ "upstream $ROUTE_SERVICE {" ]] \
            || UPSTREAMS+="upstream $ROUTE_SERVICE { server $ROUTE_SERVICE.$ROUTES_NS.svc:$ROUTE_PORT; }###"
        BACKENDS+="    ~*$ROUTE_HOST\\$ROUTE_PATH    $ROUTE_SERVICE;###"
    done <<< "$ROUTES"
}

echo "Generating maintenance mode deployment config..."
genTrustedProxiesConfig
genBypassConfig
for NS in $(echo $MAS_NAMESPACES); do genUpstreamConfig $NS; done

# Recreate config map used by deployment
oc delete configmap -n $MAINT_NS default-conf --ignore-not-found >/dev/null
CONFIG=$(sed "
            s|@TRUSTED_PROXIES@|$TRUSTED_PROXIES|g;
            s|@BYPASS_CIDRS@|$BYPASS_CIDRS|g; 
            s|@BYPASS_KEY@|$BYPASS_KEY|g; 
            s|@UPSTREAMS@|$UPSTREAMS|g; 
            s|@BACKENDS@|$BACKENDS|g
        " $SCRIPT_DIR/default.conf \
    | sed 's/###/\n/g')
oc create configmap -n $MAINT_NS default-conf --from-literal=default.conf="$CONFIG" >/dev/null

# Restart deployment to apply new config map changes
echo "Applying maintenance mode deployment config..."
oc -n $MAINT_NS rollout restart deployments/$MAINT_DEPL >/dev/null

# Setup alternative routes

# Generates alternative maintenance routes using ones from given namespace as templates
genRoutes ()  {
    ROUTES_NS=$1
    ROUTE_YQ_CLEANUP='del(.metadata.creationTimestamp, .metadata.ownerReferences, .metadata.namespace, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .spec.tls.destinationCACertificate, .status)'
    ROUTE_YQ_UPDATE='.spec.to.name = "'$MAINT_DEPL'" | .spec.port.targetPort = "http" | .spec.tls.termination = "edge" | .spec.tls.insecureEdgeTerminationPolicy = "Redirect"'
    ROUTES=$(oc get routes -n $ROUTES_NS --no-headers -o name)
    while IFS= read -r ROUTE; do
        ROUTE_NAME=$ROUTE
        # Create/update new maintenance route
        oc get -n $ROUTES_NS $ROUTE_NAME -o yaml \
            | yq "$ROUTE_YQ_CLEANUP" \
            | yq "$ROUTE_YQ_UPDATE" \
            | oc apply -n $MAINT_NS -f - >/dev/null
    done <<< "$ROUTES"
}

echo "Generating maintenance mode routes..."
for NS in $(echo $MAS_NAMESPACES); do genRoutes $NS; done
