# CI/CD Demo with Tekton and Argo CD on OpenShift

This repo is a CI/CD demo using [Tekton Pipelines](http://www.tekton.dev) for continuous integration and [Argo CD](https://argoproj.github.io/argo-cd/) for continuous delivery on OpenShift which builds and deploys the [Spring PetClinic](https://github.com/spring-projects/spring-petclinic) sample Spring Boot application. This demo creates:

* 3 namespaces for CI/CD, DEV and STAGE projects
* 1 Tekton pipeline for building the application image on every Git commit
* Argo CD (login with OpenShift credentials)
* Gitea git server (username/password: `gitea`/`openshift`)
* Sonatype Nexus (username/password: `admin`/`admin123`)
* SonarQube (username/password: `admin`/`admin`)
* Git webhooks for triggering the CI pipeline

<p align="center">
  <img width="580" src="docs/images/projects.svg">
</p>

## Prerequisites

* An OpenShift Cluster
* OpenShift Pipelines 1.7
* OpenShift GitOps 1.5
* [OpenShift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest
* [Tekton CLI](https://github.com/tektoncd/cli/releases)

## Continuous Integration

On every push to the `spring-petclinic` git repository on Gitea git server, the following steps are executed within the Tekton pipeline:

1. Code is cloned from Gitea git server and the unit-tests are run
1. Unit tests are executed and in parallel the code is analyzed by SonarQube for anti-patterns, and a dependency report is generated
1. Application is packaged as a JAR and released to Sonatype Nexus snapshot repository
1. A container image is built in DEV environment using S2I, and pushed to OpenShift internal registry, and tagged with `spring-petclinic:[branch]-[commit-sha]` and `spring-petclinic:latest`
1. Kubernetes manifests are updated in the Git repository with the image digest that was built within the pipeline
1. A pull-requested is created on config repo for merging the image digest update into the STAGE environment

![Pipeline Diagram](docs/images/ci-pipeline.svg)

## Continuous Delivery

Argo CD continuously monitor the configurations stored in the Git repository and uses [Kustomize](https://kustomize.io/) to overlay environment specific configurations when deploying the application to DEV and STAGE environments.

![Continuous Delivery](docs/images/cd.png)

## Deploy

### Prepare Cluster

1. Clone this repo

   ```bash
   git clone https://github.com/siamaksade/openshift-cicd-demo
   cd openshift-cicd-demo
   ```

1. Deploy a ROSA cluster

   ```bash
   make rosa.create
   ```

1. Use the command from the above to log into the cluster. Remember the username,password for later.

1. Install GitOps / Pipelines and the Demo infrastructure

   ```bash
   make install
   ```

## Demo Instructions


1. Once the demo is deployed, it will provide you instructions to run the demo with URLs etc prepopulated.

1. Start the deploy pipeline by making a change in the `spring-petclinic` Git repository on Gitea, or run the following:

    ```bash
    make start
    ```

1. Check pipeline run logs

    ```text
    tkn pipeline logs petclinic-build -L -f -n demo-cicd
    ```

![Pipeline Diagram](docs/images/pipeline-viz.png)

![Argo CD](docs/images/argocd.png)

The follow steps are a generic version of the instructions found in the output from above.

Demo is installed! Give it a few minutes to finish deployments and then:

1) Start the Tekton pipeline, this will perform a full build including tests:

  ./demo.sh start

2) Log into the OpenShift Console and browse to Developer -> Pipelines

  https://console-openshift-console.apps.demo-cluster.xxxx.p1.openshiftapps.com/dev-pipelines/ns/demo-cicd

4) You should see the pipeline running, click the "Last Run".

5) Check that both the dev and stage versions of petclinic are running by browsing to the
    Openshift Console and viewing the Developer -> Topology for both the demo-dev and demo-stage
    projects. You can click through to the web frontend for both versions of the app.

## Developer Experience Demo

1) Log into OpenShift Dev Spaces

    https://devspaces-openshift-operators.apps.demo-cluster.xxxx.p1.openshiftapps.com


2) Create a Workspace from the URL below.

    https://gitea-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com/gitea/spring-petclinic/raw/branch/main/devfile.yaml

3) Open Terminal -> New Terminal -> theia-ide

4) In the Terminal run the following commands:
  git config --global user.name "openshift developer"
  git config --global user.email "developer@openshift.dev"
  git remote set-url origin https://gitea:openshift@gitea-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com/gitea/spring-petclinic.git

4) Edit a file in the repository and commit to trigger the pipeline (You can
do all of this from inside the Dev Spaces Workspace, or via git in the Terminal).

  Example change the greeting in src->main->resources->messages->messages.properties

5) Check the pipeline run logs in Dev Console or Tekton CLI:

  https://console-openshift-console.apps.demo-cluster.xxxx.p1.openshiftapps.com/dev-pipelines/ns/demo-cicd

  $ tkn pipeline logs petclinic-build -L -f -n demo-cicd

6) Once the pipeline is finished Openshift GitOps will deploy the new code to the dev
    environment (It can take a few minutes to sync). You can check it here:

    https://argocd-server-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com

6) Once GitOps has completed the sync you can view the change in the dev instance of the app
    If you updated the message it should show it after the "Welcome" text.

  http://spring-petclinic-demo-dev.apps.demo-cluster.xxxx.p1.openshiftapps.com

  https://console-openshift-console.apps.demo-cluster.xxxx.p1.openshiftapps.com/dev-spring-petclinic/ns/demo-dev

7) The pipeline also created a PR to promote the change to production in the config repo.
    Merge the pull request and watch GitOps sync to the stage environment. (It can take
    a few minutes to sync)

    https://gitea-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com/gitea/spring-petclinic-config/pulls

You can find further details at:

Gitea Git Server: https://gitea-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com/explore/repos
SonarQube: https://sonarqube-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com
Sonatype Nexus: https://nexus-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com
Argo CD:  https://argocd-server-demo-cicd.apps.demo-cluster.xxxx.p1.openshiftapps.com  [login with OpenShift credentials]

## Cleanup

1. Uninstall the demo

   ```bash
   make uninstall
   ```

1. Delete the ROSA cluster

   ```bash
   make rosa.delete
   ```

## Troubleshooting

**Q: Why am I getting `unable to recognize "tasks/task.yaml": no matches for kind "Task" in version "tekton.dev/v1beta1"` errors?**

You might have just installed the OpenShift Pipelines operator on the cluster and the operator has not finished installing Tekton on the cluster yet. Wait a few minutes for the operator to finish and then install the demo.


**Q: why do I get `Unable to deploy revision: permission denied` when I manually sync an Application in Argo CD dashboard?**

When you log into Argo CD dashboard using your OpenShift credentials, your access rights in Argo CD will be assigned based on your access rights in OpenShift. The Argo CD instance in this demo is [configured](https://github.com/siamaksade/openshift-cicd-demo/blob/main/argo/argocd.yaml#L21) to map `kubeadmin` and any users in the `ocp-admins` groups in OpenShift to an Argo CD admin user. Note that `ocp-admins` group is not available in OpenShift by default. You can create this group using the following commands:

```
# create ocp-admins group
oc adm groups new ocp-admins

# give cluster admin rightsto ocp-admins group
oc adm policy add-cluster-role-to-group cluster-admin ocp-admins

# add username to ocp-admins group
oc adm groups add-users ocp-admins USERNAME
```



