#/bin/bash

# Toggle maintenance mode

SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. $SCRIPT_DIR/common.sh

argMinDie 2 $# "USAGE: <env> <action> [-f|--force]"
ocEnvDie $1

echo $2 | grep -E -i -q '^(active|activate|on|inactive|inactivate|deactivate|off)$' \
        || die "Available actions: on | off | [other synonyms - check script for details]"
ACTION=$2

[ -z "$3" ] \
        || (echo $3 | grep -E -i -q '^(-f|--force)$') \
        || die "Use -f or --force to skip confirmation prompt"
FORCE=$3

MAINT_NS=$(ocMaintNs $ENVL)
# List of namespaces which remote access will be redirected to the maintenance page
MAS_NAMESPACES=$(ocMasNsList $ENVL)

MAINT_LABEL_KEY=$(ocMaintLblKey $ENVL)
MAINT_LABEL=$(ocMaintLbl $ENVL)

case "$ACTION" in
    "active" | "activate" | "on" ) 
        echo "[/\] Activating Maintenance Mode in $ENVU environment"
        [ -n "$FORCE" ] || confirm
        . $SCRIPT_DIR/setup.sh $ENVL
        for NS in $(echo $MAS_NAMESPACES); do 
            oc label --overwrite namespace $NS $MAINT_LABEL >/dev/null
        done
        oc label namespace $MAINT_NS $MAINT_LABEL_KEY- >/dev/null
        echo "[/\] Maintenance Mode has been activated in $ENVU environment"
    ;;
    "inactive" | "inactivate" | "deactivate" | "off") 
        echo "[\/] Inactivating Maintenance Mode in $ENVU environment"
        [ -n "$FORCE" ] || confirm
        for NS in $(echo $MAS_NAMESPACES); do 
            oc label namespace $NS $MAINT_LABEL_KEY- >/dev/null
        done
        oc label --overwrite namespace $MAINT_NS $MAINT_LABEL >/dev/null
        echo "[\/] Maintenance Mode has been inactivated in $ENVU environment"
    ;;
esac
