# Maintenance Mode for IBM MAS
This repository contains example implementation of the maintenance mode for IBM Maximo Application Suite.  
When maintenance mode is **ON** then static content is served while accessing MAS services.  

This tool can be used during service windows when either MAS services should not be accessed by the end users in order not to interfere with maintenance activities and/or to gracefully handle MAS services unavailability, caused by downtimes (e.g. during MAS Manage `updatedb` execution). 

Static content served to the end users can be customized by modifying [`maintenance.html`](maintenance.html) file content (see example below). It's important though to notice that at this point configuration supports single-page HTML files, with all images and styles embedded, which size does not exceed 1MB. In case of a need to serve more sophisticated content it might be required to build dedicated maintenance deployment image. Alternatively, since under the hood maintenance deployment is fully functional *nginx*, then all other configuration techniques can be employed to adjust the behavior, e.g. automatic redirect to an externally managed SharePoint/Teams site, etc. For the list of all available options refer to [the official nginx documentation](https://nginx.org/en/docs/).

![Example maintenance mode landing page](maintenance.png)

By default maintenance mode configuration activates for all end users **except of** ones whitelisted explicitly by IP in [`default.conf`](default.conf) (ref. `bypass` map) or in [`bypass-cidrs.list`](./bypass-cidrs.list) file. Alternatively, maintenance mode can be bypassed by including `X-Bypass-Key` HTTP header to every incoming request. This effectively allows for certain users to maintain regular MAS behavior, regardless of whether maintenance mode is **ON** or **OFF**. The tool automatically whitelists all worker nodes' IPs. This is required in order to allow cross-node communication when PODs are referring to each other using routes (e.g. MAS Manage OIDC cookie validation). Additional maintenance mode bypass matching rules can be added by updating [default.conf](default.conf) file. Changes will be re-applied every time maintenance mode is activated.

## Scope
This tool currently supports MAS Core and Manage but can easily be extended to handle other MAS components.

## Implementation Details
![Implementation details](maintenance.gif)

The solution consists of following configurations:
* Update the **default** ingress controller by excluding all routes which are to be used in the maintenance mode (ref. [Sharding the default Ingress Controller](https://community.ibm.com/community/user/asset-facilities/discussion/Sharding%20the%20default%20Ingress%20Controller), routes under namespaces **not** labeled as `router-mode=inactive`). 
* Configure new **maintenance** namespace, service and deployment (acting as a reverse proxy) which are meant to handle user traffic during the service window, when maintenance mode is **ON**. 
* Generate clones of MAS Core, MAS Manage, etc. routes (a.k.a. *maintenance routes*) and repoint `.spec.to.name` and `.spec.to.targetPort` to the service created in previous step.
* Label newly created **maintenance** namespace with `router-mode=inactive`.

Once everything is in place Maintenance Mode can be:
* **Enabled** by labeling original MAS Core, MAS Manage namespaces with `router-mode=inactive` and removing `router-mode=inactive` label from **maintenance** namespace.
* **Disabled** by doing the opposite of **Enable**.

### Additional Comments and Alternatives

#### Ingress Controller sharding by using [namespace](https://docs.openshift.com/container-platform/4.14/networking/ingress-sharding.html#nw-ingress-sharding-namespace-labels_ingress-sharding) vs [route](https://docs.openshift.com/container-platform/4.14/networking/ingress-sharding.html#nw-ingress-sharding-route-labels_ingress-sharding) labels
Even though it's perfectly OK to use any of the sharding techniques it's been decided to use namespace labels to be able to easily keep new configurations away from standard MAS deployment objects. 

## Prerequisites
Minimum requirements to run this tool is Linux environment with following utilities:
* shell (tested with Ubuntu Linux `bash` and MacOS `zsh`)
* grep
* awk
* sed
* openssl
* [yq](https://mikefarah.gitbook.io/yq)
* [OpenShift CLI](https://docs.openshift.com/container-platform/4.14/cli_reference/openshift_cli/getting-started-cli.html) 

**NOTE:** The tool deploys *nginx-based reverse proxy* using publicly available bare `nginxinc/nginx-unprivileged` image. In air-gapped or heavily restricted environments it might be required to make it avaliable locally or change it to any other equivalent one (ref. [`deployment.yaml`](deployment.yaml)).

## Usage
Activate or deactivate maintenance mode by issuing commands like below:
```bash
export ENV=<env>
export ACTION=<action>
./maintenance.sh <env> <action> [-f|--force]
```
where:
* `<env>` - case insensitive environment name (DEV, TEST, PROD)
* `<action>` - `on`, `off` or one of few more synonyms - check the script for details
* `-f|--force` - optional, when specified *Maintenance Mode* activation/inactivation prompt is skipped

## Customization
Refer to `FIXME` labels accross the files to adjust default tool's behavior. The most common customization points are:
* [common.sh](common.sh) - update common names which by default heavily follow environment naming conventions.
* [default.conf](default.conf)
    * `$bypass` map to change whitelisting rules (request specific values and matched content) and therefore let more users in when maintenance mode is **ON**
    * `server` section to adjust nginx reverse proxy deployment behavior (ref. [official nginx documentation](https://nginx.org/en/docs/))
* [maintenance.html](maintenance.html) change static fontent served to the end users when maintenance mode is **ON**