#/bin/bash

# Sets up all components required by maintenance mode
# 1. Update default ingress controller
# 2. Create new ingress controller to handle maintenance mode
# 3. Setup Project
# 4. Setup Deployment
# 5. Setup alternative routes

SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. $SCRIPT_DIR/common.sh

argDie 1 $# "USAGE: <env>"
ocEnvDie $1

MAINT_NS=$(ocMaintNs $ENVL)
# Name of the ingress controller dedicated for maintenance mode
MAINT_IC=$(ocMaintIc $ENVL)
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

# In non-standalone environments (e.g. DEV and TEST deployed to one OCP cluster) allow route admission accross namespaces. 
# This is to be able to handle maintenance mode for multiple environments at the same time and yet do not experience ingress 
# controller host conflicts
ocStandaloneEnv $ENVL \
    || ocIcYaml default | yq -e 'select(.spec.routeAdmission.namespaceOwnership == "InterNamespaceAllowed")' >/dev/null 2>&1 \
    || {
        echo "Enabling cross-namespace route admission for the default ingress controller..." \
        && ocIcYaml default \
            | yq '.spec.routeAdmission.namespaceOwnership = "InterNamespaceAllowed"' \
            | oc apply -f -
    }

# Create ingress controller (if needed)
ocIcYaml $MAINT_IC >/dev/null 2>&1 \
    || {
        echo "Creating  maintenance mode ingress controller..." \
        && cat $SCRIPT_DIR/ingress-controller.yaml \
            | NAME=$MAINT_IC DOMAIN=$(ocDomain $ENVL) KEY=$MAINT_LABEL_KEY VALUE=$MAINT_LABEL_VALUE \
                yq -e '.metadata.name = env(NAME) | .spec.domain = env(DOMAIN) | .spec.namespaceSelector.matchLabels[env(KEY)] = env(VALUE)' \
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

# Generates nginx config containing default reverse proxy bypass rules for cross node communication
# Output variable is: BYPASSES
genBypassConfig () {
    # Generate exception rules for worker nodes
    NODES=$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers -o name)
    while IFS= read -r NODE; do
        NODE_IP=$(oc get $NODE -o yaml | yq '.status.addresses[] | select(.type == "InternalIP") | .address')
        BYPASSES+="    \"$NODE_IP\"    true;###"
    done <<< "$NODES"
}

# Generates nginx config entries for given namespace
# Output variables are:
# 1. UPSTREAMS - list of target servers
# 2. BACKENDS - list of backends to map
genUpstreamConfig () {
    ROUTES_NS=$1
    # Get more route details in order to sort results.
    # This will affect nginx matching order so routes using the same host
    # need to be sorted the way that one witout any path (/) gets last
    ROUTES=$(oc get routes -n $ROUTES_NS --no-headers -o custom-columns=":metadata.name,:spec.host,:spec.path" \
        | sort -k2b,2 -k3br,3)
    while IFS= read -r ROUTE; do
        ROUTE_NAME=$(echo "$ROUTE" | awk '{print $1}')
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
genBypassConfig
for NS in $(echo $MAS_NAMESPACES); do genUpstreamConfig $NS; done

# Recreate config map used by deployment
oc delete configmap -n $MAINT_NS default-conf --ignore-not-found >/dev/null
# Save config in a temporary file as oc cli does not allow to create config maps from standard input
CONFIG_FILE=$(mktemp)
sed "s/@BYPASSES@/$BYPASSES/g; s/@UPSTREAMS@/$UPSTREAMS/g; s/@BACKENDS@/$BACKENDS/g" $SCRIPT_DIR/default.conf \
    | sed 's/###/\n/g' \
    > $CONFIG_FILE
oc create configmap -n $MAINT_NS default-conf --from-file=default.conf=$CONFIG_FILE >/dev/null
rm -f $CONFIG_FILE

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
