#!/bin/sh

set -e

LOGFILE="test-log"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  echo "Cleaning up before exiting"
  # leave the namespace for debugging purpose. A new PR will refresh the namespace anyways.
  # helm uninstall ${RELEASE_NAME} -n ${NAME_SPACE}
  # oc delete namespace ${NAME_SPACE}
  rm -rf ~/tmpbin
}

trap cleanup EXIT

add_helm_repos() {
  helm version

  declare -a repos=("bitnami=https://charts.bitnami.com/bitnami" "backstage=https://backstage.github.io/charts" "${HELM_REPO_NAME}=${HELM_REPO_URL}")

  for repo in "${repos[@]}"; do
    key="${repo%%=*}"
    value="${repo##*=}"

    if ! helm repo list | grep -q "^$key"; then
      helm repo add "$key" "$value"
    else
      echo "Repository $key already exists - updating repository instead."
    fi
  done

  helm repo update
}

install_ibmcloud() {
  if [[ -x "$(command -v ibmcloud)" ]]; then
    echo "ibmcloud is already installed."
  else
    curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
    echo "the latest ibmcloud cli installed successfully."
  fi
}

install_oc() {
  if [[ -x "$(command -v oc)" ]]; then
    echo "oc is already installed."
  else
    curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz
    tar -xf oc.tar.gz
    mv oc /usr/local/bin/
    rm oc.tar.gz
    echo "oc installed successfully."
  fi
}

install_helm() {
  if [[ -x "$(command -v helm)" ]]; then
    echo "Helm is already installed."
  else
    echo "Installing Helm 3 client"
    mkdir ~/tmpbin && cd ~/tmpbin
    HELM_INSTALL_DIR=$(pwd)
    curl -sL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash -f
    export PATH=${HELM_INSTALL_DIR}:$PATH
    echo "helm client installed successfully."
  fi
}

uninstall_helmchart() {
  local project=$1
  local release=$2
  if helm list -n ${project} | grep -q ${release}; then
    echo "Chart already exists. Removing it before install."
    helm uninstall ${release} -n ${project}
  fi
}

configure_namespace() {
  local project=$1
  if oc get namespace ${project} >/dev/null 2>&1; then
    echo "Namespace ${project} already exists! refreshing namespace"
    oc delete namespace ${project}
  fi
  oc create namespace ${project}
  oc config set-context --current --namespace=${project}
}

apply_yaml_files() {
  local dir=$1
  local project=$2
  echo "NAME SPACE ${project}"

  # Update namespace and other configurations in YAML files
  local files=("$dir/resources/service_account/service-account-rhdh.yaml"
    "$dir/resources/cluster_role_binding/cluster-role-binding-k8s.yaml"
    "$dir/resources/cluster_role_binding/cluster-role-binding-ocm.yaml"
    "$dir/resources/deployment/deployment-test-app-component.yaml"
    "$dir/auth/secrets-rhdh-secrets.yaml")

  for file in "${files[@]}"; do
    sed -i "s/namespace:.*/namespace: $project/g" "$file"
  done

  sed -i "s/backstage.io\/kubernetes-id:.*/backstage.io\/kubernetes-id: $K8S_PLUGIN_ANNOTATION/g" "$dir/resources/deployment/deployment-test-app-component.yaml"

  for key in GITHUB_APP_APP_ID GITHUB_APP_CLIENT_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_CLIENT_SECRET GITHUB_APP_WEBHOOK_URL GITHUB_APP_WEBHOOK_SECRET KEYCLOAK_CLIENT_SECRET OCM_CLUSTER_TOKEN ACR_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET; do
    sed -i "s|$key:.*|$key: ${!key}|g" "$dir/auth/secrets-rhdh-secrets.yaml"
  done

  oc apply -f $dir/resources/service_account/service-account-rhdh.yaml --namespace=${project}
  oc apply -f $dir/auth/service-account-rhdh-secret.yaml --namespace=${project}
  oc apply -f $dir/auth/secrets-rhdh-secrets.yaml --namespace=${project}
  oc apply -f $dir/resources/deployment/deployment-test-app-component.yaml --namespace=${project}
  oc new-app https://github.com/janus-qe/test-backstage-customization-provider --namespace=${project}
  oc expose svc/test-backstage-customization-provider --namespace=${project}
  oc apply -f $dir/resources/cluster_role/cluster-role-k8s.yaml
  oc apply -f $dir/resources/cluster_role_binding/cluster-role-binding-k8s.yaml
  oc apply -f $dir/resources/cluster_role/cluster-role-ocm.yaml
  oc apply -f $dir/resources/cluster_role_binding/cluster-role-binding-ocm.yaml

  # obtain K8S_SERVICE_ACCOUNT_TOKEN, K8S_CLUSTER_NAME, K8S_CLUSTER_API_SERVER_URL and add them to secrets-rhdh-secrets.yaml
  oc get secret rhdh-k8s-plugin-secret -o yaml >$dir/auth/service-account-rhdh-token.yaml

  TOKEN=$(grep 'token:' $dir/auth/service-account-rhdh-token.yaml | awk '{print $2}')

  sed -i "s/K8S_SERVICE_ACCOUNT_TOKEN:.*/K8S_SERVICE_ACCOUNT_TOKEN: $TOKEN/g" $dir/auth/secrets-rhdh-secrets.yaml
  sed -i "s/K8S_CLUSTER_API_SERVER_URL:.*/K8S_CLUSTER_API_SERVER_URL: $ENCODED_API_SERVER_URL/g" $dir/auth/secrets-rhdh-secrets.yaml
  sed -i "s/K8S_CLUSTER_NAME:.*/K8S_CLUSTER_NAME: $ENCODED_CLUSTER_NAME/g" $dir/auth/secrets-rhdh-secrets.yaml

  # Cleanup temp file
  rm $dir/auth/service-account-rhdh-token.yaml

  if [[ "${project}" == "showcase-rbac" ]]; then
    oc apply -f $dir/resources/config_map/configmap-app-config-rhdh-rbac.yaml --namespace=${project}
  else
    oc apply -f $dir/resources/config_map/configmap-app-config-rhdh.yaml --namespace=${project}
  fi
  oc apply -f $dir/resources/config_map/configmap-rbac-policy-rhdh.yaml --namespace=${project}
  oc apply -f $dir/auth/secrets-rhdh-secrets.yaml --namespace=${project}

  # pipelines (required for tekton)
  sleep 20 # wait for Pipeline Operator to be ready
  oc apply -f "$dir"/resources/pipeline-run/hello-world-pipeline.yaml
  oc apply -f "$dir"/resources/pipeline-run/hello-world-pipeline-run.yaml
}

run_tests() {
  local project=$1
  cd $DIR/../../e2e-tests
  yarn install
  yarn playwright install

  Xvfb :99 &
  export DISPLAY=:99

  (
    set -e
    echo Using PR container image: ${TAG_NAME}
    yarn "$project"
  ) |& tee "/tmp/${LOGFILE}"

  RESULT=${PIPESTATUS[0]}

  pkill Xvfb

  mkdir -p ${ARTIFACT_DIR}/$project/test-results
  cp -a /tmp/backstage-showcase/e2e-tests/test-results/* ${ARTIFACT_DIR}/$project/test-results

  ansi2html <"/tmp/${LOGFILE}" >"/tmp/${LOGFILE}.html"
  cp -a "/tmp/${LOGFILE}.html" ${ARTIFACT_DIR}/${project}
  exit ${RESULT}
}

check_backstage_running() {
  local release_name=$1
  local namespace=$2
  local url="https://${release_name}-backstage-${namespace}.${K8S_CLUSTER_ROUTER_BASE}"

  # Maximum number of attempts to check URL
  local max_attempts=30
  # Time in seconds to wait
  local wait_seconds=30

  echo "Checking if Backstage is up and running at $url"

  for ((i = 1; i <= max_attempts; i++)); do
    # Get the status code
    local http_status=$(curl --insecure -I -s "$url" | grep HTTP | awk '{print $2}')

    # Check if the status code is 200
    if [[ $http_status -eq 200 ]]; then
      echo "Backstage is up and running!"
      export BASE_URL=$url
      echo "######## BASE URL ########"
      echo "$BASE_URL"
      return 0
    else
      echo "Attempt $i of $max_attempts: Backstage not yet available (HTTP Status: $http_status)"
      sleep $wait_seconds
    fi
  done

  echo "Failed to reach Backstage at $BASE_URL after $max_attempts attempts." | tee -a "/tmp/${LOGFILE}"
  cp -a "/tmp/${LOGFILE}" ${ARTIFACT_DIR}
  return 1
}

installPipelinesOperator() {
  local dir=$1
  DISPLAY_NAME="Red Hat OpenShift Pipelines"

  if oc get csv -n "openshift-operators" | grep -q "$DISPLAY_NAME"; then
    echo "Red Hat OpenShift Pipelines operator is already installed."
  else
    echo "Red Hat OpenShift Pipelines operator is not installed. Installing..."
    oc apply -f "$dir"/resources/pipeline-run/pipelines-operator.yaml
  fi

}
initiate_deployments() {
  configure_namespace ${NAME_SPACE}
  installPipelinesOperator $DIR
  install_helm
  uninstall_helmchart ${NAME_SPACE} ${RELEASE_NAME}

  cd $DIR
  apply_yaml_files $DIR "$NAME_SPACE"
  add_helm_repos
  helm upgrade -i "${RELEASE_NAME}" -n ${NAME_SPACE} ${HELM_REPO_NAME}/${HELM_IMAGE_NAME} --version ${CHART_VERSION} -f $DIR/value_files/${HELM_CHART_VALUE_FILE_NAME} --set global.clusterRouterBase=${K8S_CLUSTER_ROUTER_BASE} --set upstream.backstage.image.tag=${TAG_NAME}

  configure_namespace ${NAME_SPACE_RBAC}
  installPipelinesOperator $DIR
  uninstall_helmchart ${NAME_SPACE_RBAC} ${RELEASE_NAME_RBAC}
  apply_yaml_files $DIR "${NAME_SPACE_RBAC}"
  helm upgrade -i ${RELEASE_NAME_RBAC} -n ${NAME_SPACE_RBAC} ${HELM_REPO_NAME}/${HELM_IMAGE_NAME} --version ${CHART_VERSION} -f $DIR/value_files/${HELM_CHART_VALUE_FILE_NAME} --set global.clusterRouterBase=${K8S_CLUSTER_ROUTER_BASE} --set upstream.backstage.image.tag=${TAG_NAME}
}

check_and_test() {
  local release_name=$1
  local namespace=$2
  check_backstage_running $release_name $namespace
  backstage_status=$?
  echo "Display pods for verification..."
  oc get pods -n $namespace
  if [ $backstage_status -ne 0 ]; then
    echo "Backstage is not running. Exiting..."
    exit 1
  fi
    run_tests $namespace
}

main() {
  echo "Log file: ${LOGFILE}"
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source ./.ibm/pipelines/env_variables.sh
  echo "OPENSHIFT_CLUSTER_ID : $OPENSHIFT_CLUSTER_ID"

  install_ibmcloud
  ibmcloud version
  ibmcloud config --check-version=false
  install_oc
  oc version --client
  oc login --token=${K8S_CLUSTER_TOKEN} --server=${K8S_CLUSTER_URL}

  API_SERVER_URL=$(oc whoami --show-server)
  K8S_CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')

  # Encode in Base64
  ENCODED_API_SERVER_URL=$(echo "$API_SERVER_URL" | base64)
  ENCODED_CLUSTER_NAME=$(echo "my-cluster" | base64)

  initiate_deployments
  check_and_test ${RELEASE_NAME} ${NAME_SPACE}
  check_and_test ${RELEASE_NAME_RBAC} ${NAME_SPACE_RBAC}
}

main
