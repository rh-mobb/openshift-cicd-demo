#!/bin/bash

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="demo"
declare COMMAND="help"

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    rosa-create|rosa-delete|install|uninstall|start)
      COMMAND=$1
      shift
      ;;
    -p|--project-prefix)
      PRJ_PREFIX=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *)
      break
  esac
done

declare -r dev_prj="$PRJ_PREFIX-dev"
declare -r stage_prj="$PRJ_PREFIX-stage"
declare -r cicd_prj="$PRJ_PREFIX-cicd"

command.help() {
  cat <<-EOF

  Usage:
      demo [command] [options]

  Example:
      demo install --project-prefix mydemo

  COMMANDS:
      rosa-create                    creates a ROSA cluster
      rosa-delete                    deletes the ROSA cluster
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      start                          Starts the deploy DEV pipeline
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to demo project names e.g. PREFIX-dev
EOF
}

command.install() {
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Deploying OpenShift GitOps"
  oc apply -f ./infra/gitops.yaml

  info "Deploying OpenShift Pipelines"
  oc apply -f ./infra/pipelines.yaml

  info "Deploying OpenShift Dev Spaces"
  oc apply -f ./infra/devspaces.yaml

  while [[ $(oc -n openshift-operators get subscriptions.operators.coreos.com devspaces -o jsonpath='{.status.conditions[0].status}') != "False" ]]; do
    echo -n "."
    sleep 5
  done
  while ! oc get crd checlusters.org.eclipse.che  >/dev/null 2>/dev/null; do
    echo -n "."
    sleep 5
  done
  echo ""

  info "Deploying OpenShift Dev Spaces UI"
  oc apply -f ./infra/devspaces-ui.yaml

  info "Wait for OpenShift Dev Spaces UI route"

  until oc get route devspaces -n openshift-operators >/dev/null 2>/dev/null
  do
    echo -n "."
    sleep 3
  done
    echo ""

  info "Wait for tekton operator webhook to be ready"
  until oc -n openshift-operators get endpoints tekton-operator-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>/dev/null
  do
    echo -n "."
    sleep 3
  done
    echo ""

  info "Wait for tekton CRDs to be ready"
  until oc explain triggerbinding >/dev/null 2>/dev/null
  do
    echo -n "."
    sleep 3
  done
    echo ""

  DEVSPACES_HOSTNAME=$(oc get route devspaces -o template --template='{{.spec.host}}' -n openshift-operators)
  info "OpenShift Dev Spaces UI is available at http://$DEVSPACES_HOSTNAME"

  info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
  oc get ns $cicd_prj 2>/dev/null  || {
    oc new-project $cicd_prj
  }
  oc get ns $dev_prj 2>/dev/null  || {
    oc new-project $dev_prj
  }
  oc get ns $stage_prj 2>/dev/null  || {
    oc new-project $stage_prj
  }

  info "Configure service account permissions for pipeline"
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $dev_prj
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $stage_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$dev_prj:default -n $cicd_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$stage_prj:default -n $cicd_prj

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -n $cicd_prj -f infra/gitea.yaml -f infra/nexus.yaml -f infra/sonarqube.yaml
  GITEA_HOSTNAME=$(oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj)

  info "Deploying pipeline and tasks to $cicd_prj namespace"
  oc apply -f tasks -n $cicd_prj
  sed "s#https://github.com/siamaksade#http://$GITEA_HOSTNAME/gitea#g" pipelines/pipeline-build.yaml | oc apply -f - -n $cicd_prj

  oc apply -f triggers -n $cicd_prj

  info "Initiatlizing git repository in Gitea and configuring webhooks"
  sed "s/@HOSTNAME/$GITEA_HOSTNAME/g" config/gitea-configmap.yaml | oc create -f - -n $cicd_prj
  oc rollout status deployment/gitea -n $cicd_prj
  oc create -f config/gitea-init-taskrun.yaml -n $cicd_prj

  sleep 10

  info "Configure Argo CD"

  cat << EOF > argo/tmp-argocd-app-patch.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-spring-petclinic
spec:
  destination:
    namespace: $dev_prj
  source:
    repoURL: https://$GITEA_HOSTNAME/gitea/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stage-spring-petclinic
spec:
  destination:
    namespace: $stage_prj
  source:
    repoURL: https://$GITEA_HOSTNAME/gitea/spring-petclinic-config
EOF
  oc apply -k argo -n $cicd_prj

  info "Wait for Argo CD route..."

  until oc get route argocd-server -n $cicd_prj >/dev/null 2>/dev/null
  do
    sleep 3
  done

  oc patch argocd argocd -n $cicd_prj --type=merge -p='{"spec":{"server":{"insecure":true,"route":{"enabled":true,"tls":{"insecureEdgeTerminationPolicy":"Redirect","termination":"edge"}}}}}'
  info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
  oc label ns $dev_prj argocd.argoproj.io/managed-by=$cicd_prj
  oc label ns $stage_prj argocd.argoproj.io/managed-by=$cicd_prj

  oc project $cicd_prj

  CONSOLE=$(oc whoami --show-console)

  info "Wait for initial deployments of dev and stage applications"
  until oc -n $dev_prj get route spring-petclinic >/dev/null 2>/dev/null
  do
    sleep 3
    echo -n .
  done
  until oc -n $stage_prj get route spring-petclinic >/dev/null 2>/dev/null
  do
    sleep 3
    echo -n .
  done
  echo ""

  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then

  1) Start the Tekton pipeline, this wil perform a full build and run tests:

    make start

  2) Log into the OpenShift Console and browse to Developer -> Pipelines

    $CONSOLE/dev-pipelines/ns/$cicd_prj

  4) You should see the pipeline running, click the "Last Run".

  5) Wait for the pipeline to finish, you can waitch the Logs in the console, or by running:

     tkn pipeline logs petclinic-build -L -f -n $cicd_prj

  6) Check that both the dev and stage versions of petclinic are running by browsing to the
      Openshift Console and viewing the Developer -> Topology for both the $dev_prj and $stage_prj
      projects. You can click through to the web frontend for both versions of the app.

    Dev   -> http://$(oc get route spring-petclinic -o template --template='{{.spec.host}}' -n $dev_prj)

    Stage -> http://$(oc get route spring-petclinic -o template --template='{{.spec.host}}' -n $stage_prj)


  ## Developer Experience Demo

  1) Log into OpenShift Dev Spaces

     https://$DEVSPACES_HOSTNAME


  2) Create a Workspace from the URL below.

     https://$GITEA_HOSTNAME/gitea/spring-petclinic/raw/branch/main/devfile.yaml

  3) Open Terminal -> New Terminal -> theia-ide

  4) In the Terminal run the following commands:
    git config --global user.name "openshift developer"
    git config --global user.email "developer@openshift.dev"
    git remote set-url origin https://gitea:openshift@$GITEA_HOSTNAME/gitea/spring-petclinic.git

  4) Edit a file in the repository and commit to trigger the pipeline (You can
  do all of this from inside the Dev Spaces Workspace, or via git in the Terminal).

    Example change the greeting in src->main->resources->messages->messages.properties

  5) Check the pipeline run logs in Dev Console or Tekton CLI:

    $CONSOLE/dev-pipelines/ns/$cicd_prj

    \$ tkn pipeline logs petclinic-build -L -f -n $cicd_prj

  6) The pipeline will take some time. While its running, did you notice the petclinic app is
     not protected by TLS? Let's change the app config repo and let OpenShift GitOps fix it for us.

     Browse to https://$GITEA_HOSTNAME/gitea/spring-petclinic-config/src/branch/master/app/route.yaml

     Log in using gitea/openshift and edit the file, Uncomment the "TLS" section of the route and save it.

     After a few minutes OpenShift GitOps will have fixed it and if you refresh the petclinic apps in dev
     and stage, you should see the app now protected by TLS.

  7) Once the pipeline is finished Openshift GitOps will deploy the new code to the dev
     environment (It can take a few minutes to sync). You can check it here:

     https://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj)

  8) Once GitOps has completed the sync you can view the change in the dev instance of the app
     If you updated the message it should show it after the "Welcome" text.

    http://$(oc get route spring-petclinic -o template --template='{{.spec.host}}' -n $dev_prj)

  9) The pipeline also created a PR to promote the change to production in the config repo.
     Merge the most recent pull request and watch GitOps sync to the stage environment. (It can take
     a few minutes to sync)

     https://$GITEA_HOSTNAME/gitea/spring-petclinic-config/pulls

  You can find further details at:

  OpenShift Console: $CONSOLE
  Gitea Git Server:  https://$GITEA_HOSTNAME/explore/repos
  SonarQube:         https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus:    https://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)
  Argo CD:           https://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj)  [login with OpenShift credentials]

############################################################################
############################################################################
EOF
}

command.start() {
  # oc create -f runs/pipeline-build-run.yaml -n $cicd_prj
  GITEA_HOSTNAME=$(oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj)
  cat runs/pipeline-build-run.yaml| sed "s|__APP_SOURCE_GIT__|https://$GITEA_HOSTNAME/gitea/spring-petclinic.git|" | sed "s|__APP_MANIFESTS_GIT__|https://$GITEA_HOSTNAME/gitea/spring-petclinic-config.git|" | oc create -f -
}

command.uninstall() {
  oc delete project $dev_prj $stage_prj $cicd_prj
  info "waiting for namespaces to be deleted"
  while oc get namespace $cicd_prj >/dev/null 2>/dev/null; do
    sleep 3
    echo -n "."
  done
  echo
}

command.rosa-create() {
  rosa create cluster -c $PRJ_PREFIX-cluster --enable-autoscaling --min-replicas=2 --max-replicas=6 --watch
  rosa create admin -c $PRJ_PREFIX-cluster
}

command.rosa-delete() {
  rosa delete cluster -c $PRJ_PREFIX-cluster --watch --yes
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd $SCRIPT_DIR
  $fn
  return $?
}

main
