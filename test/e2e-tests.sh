#!/bin/bash

# Copyright 2018 Google, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script runs the end-to-end tests against Elafros built from source.
# It is started by prow for each PR.
# For convenience, it can also be executed manually.

# If you already have the *_OVERRIDE environment variables set, call
# this script with the --run-tests arguments and it will start elafros in
# the cluster and run the tests.

# Calling this script without arguments will create a new cluster in
# project $PROJECT_ID, start elafros in it, run the tests and delete the
# cluster. $DOCKER_REPO_OVERRIDE must point to a valid writable docker repo.

# Test cluster parameters and location of generated test images
readonly E2E_CLUSTER_NAME=ela-e2e-cluster
readonly E2E_CLUSTER_ZONE=us-east1-d
readonly E2E_CLUSTER_NODES=2
readonly E2E_CLUSTER_MACHINE=n1-standard-2
readonly GKE_VERSION=v1.9.4-gke.1
readonly E2E_DOCKER_BASE=gcr.io/elafros-e2e-tests
readonly TEST_RESULT_FILE=/tmp/ela-e2e-result

# Unique identifier for this test execution
# uuidgen is not available in kubekins images
readonly UUID=$(cat /proc/sys/kernel/random/uuid)

# Useful environment variables
[[ $USER == "prow" ]] && IS_PROW=1 || IS_PROW=0
readonly IS_PROW
readonly SCRIPT_CANONICAL_PATH="$(readlink -f ${BASH_SOURCE})"
readonly ELAFROS_ROOT="$(dirname ${SCRIPT_CANONICAL_PATH})/.."

# Save *_OVERRIDE variables in case a bazel cleanup if required.
readonly OG_DOCKER_REPO="${DOCKER_REPO_OVERRIDE}"
readonly OG_K8S_CLUSTER="${K8S_CLUSTER_OVERRIDE}"
readonly OG_K8S_USER="${K8S_USER_OVERRIDE}"

function header() {
  echo "================================================="
  echo $1
  echo "================================================="
}

function cleanup_bazel() {
  header "Cleaning up Bazel"
  export DOCKER_REPO_OVERRIDE="${OG_DOCKER_REPO}"
  export K8S_CLUSTER_OVERRIDE="${OG_K8S_CLUSTER}"
  export K8S_USER_OVERRIDE="${OG_K8S_CLUSTER}"
  # --expunge is a workaround for https://github.com/elafros/elafros/issues/366
  bazel clean --expunge
}

function teardown() {
  header "Tearing down test environment"
  # Free resources in GCP project.
  if (( ! USING_EXISTING_CLUSTER )); then
    bazel run //:everything.delete
  fi

  # Delete Elafros images when using prow.
  if (( IS_PROW )); then
    delete_elafros_images
  else
    cleanup_bazel
  fi
}

function wait_for_elafros() {
  echo -n "Waiting for Elafros to come up"
  for i in {1..150}; do  # timeout after 5 minutes
    if [[ $(kubectl -n ela-system get pods | grep "Running" | wc -l) == 2 ]]; then
      echo -e "\nElafros is up:"
      kubectl -n ela-system get pods
      return 0
    fi
    echo -n "."
    sleep 2
  done
  echo -e "\n\nERROR: timeout waiting for Elafros to come up"
  return 1
}

function delete_elafros_images() {
  local all_images=""
  for image in build-controller creds-image ela-autoscaler ela-controller ela-queue ela-webhook git-image ; do
    all_images="${all_images} ${ELA_DOCKER_REPO}/${image}"
  done
  gcloud -q container images delete ${all_images}
}

function exit_if_test_failed() {
  [[ $? -ne 0 ]] && exit 1
}

# End-to-end tests

function run_conformance_tests() {
  header "Running conformance tests"
  echo -e "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: pizzaplanet" | kubectl create -f -
  go test -v ./test/conformance -ginkgo.v -dockerrepo ${E2E_DOCKER_BASE}/ela-conformance-test
}

function run_hello_world() {
  header "Running hello world"
  bazel run //sample/helloworld:everything.create && return 0
  echo "Route:"
  kubectl get route -o yaml
  echo "Configuration:"
  kubectl get configurations -o yaml
  echo "Revision:"
  kubectl get revisions -o yaml
  echo "Pods:"
  kubectl get pods
  local service_host=""
  local service_ip=""
  for i in {1..150}; do  # timeout after 5 minutes
    echo "Waiting for Ingress to come up"
    if [[ $(kubectl get ingress | grep example | wc -w) == 5 ]]; then
      service_host=$(kubectl get route route-example -o jsonpath="{.status.domain}")
      service_ip=$(kubectl get ingress route-example-ela-ingress -o jsonpath="{.status.loadBalancer.ingress[*]['ip']}")
      echo -e -n "Ingress is at $service_ip / $service_host"
      break
    fi
    sleep 2
  done
  if [[ -z $service_ip || -z $service_host ]]; then
    echo -e "\nERROR: timeout waiting for Ingress to come up"
    return 1
  fi
  local output=$(curl --header "Host:$service_host" http://${service_ip})
  local result=0
  if [[ $output != "Hello World: shiniestnewestversion!" ]]; then
    echo "ERROR: unexpected output [$output]"
    result=1
  fi
  bazel run //sample/helloworld:everything.delete  # ignore errors
  return $result
}

# Script entry point.

cd ${ELAFROS_ROOT}

# Show help if bad arguments are passed.
if [[ -n $1 && $1 != "--run-tests" ]]; then
  echo "usage: $0 [--run-tests]"
  exit 1
fi

# No argument provided, create the test cluster.

if [[ -z $1 ]]; then
  header "Creating test cluster"
  # Smallest cluster required to run the end-to-end-tests
  CLUSTER_CREATION_ARGS=(
    --gke-create-args="--enable-autoscaling --min-nodes=1 --max-nodes=${E2E_CLUSTER_NODES} --scopes=cloud-platform"
    --gke-shape={\"default\":{\"Nodes\":${E2E_CLUSTER_NODES}\,\"MachineType\":\"${E2E_CLUSTER_MACHINE}\"}}
    --provider=gke
    --deployment=gke
    --gcp-node-image=cos
    --cluster="${E2E_CLUSTER_NAME}"
    --gcp-zone="${E2E_CLUSTER_ZONE}"
    --gcp-network=ela-e2e-net
    --gke-environment=prod
  )
  if (( ! IS_PROW )); then
    CLUSTER_CREATION_ARGS+=(--gcp-project=${PROJECT_ID:?"PROJECT_ID must be set to the GCP project where the tests are run."})
  else
    # On prow, set bogus SSH keys for kubetest, we're not using them.
    touch $HOME/.ssh/google_compute_engine.pub
    touch $HOME/.ssh/google_compute_engine
  fi
  # Clear user and cluster variables, so they'll be set to the test cluster.
  # DOCKER_REPO_OVERRIDE is not touched because when running locally it must
  # be a writeable docker repo.
  export K8S_USER_OVERRIDE=
  export K8S_CLUSTER_OVERRIDE=
  # Assume test failed (see more details at the end of this script).
  echo -n "1"> ${TEST_RESULT_FILE}
  kubetest "${CLUSTER_CREATION_ARGS[@]}" \
    --up \
    --down \
    --extract "${GKE_VERSION}" \
    --test-cmd "${SCRIPT_CANONICAL_PATH}" \
    --test-cmd-args --run-tests
  exit $(cat ${TEST_RESULT_FILE})
fi

# --run-tests passed as first argument, run the tests.

# Set the required variables if necessary.

if [[ -z ${K8S_USER_OVERRIDE} ]]; then
  export K8S_USER_OVERRIDE=$(gcloud config get-value core/account)
fi

USING_EXISTING_CLUSTER=1
if [[ -z ${K8S_CLUSTER_OVERRIDE} ]]; then
  USING_EXISTING_CLUSTER=0
  export K8S_CLUSTER_OVERRIDE=$(kubectl config current-context)
  # Fresh new test cluster, set cluster-admin.
  # Get the password of the admin and use it, as the service account (or the user)
  # might not have the necessary permission.
  passwd=$(gcloud container clusters describe ${E2E_CLUSTER_NAME} --zone=${E2E_CLUSTER_ZONE} | \
    grep password | cut -d' ' -f4)
  kubectl --username=admin --password=$passwd create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin \
    --user=${K8S_USER_OVERRIDE}
fi
readonly USING_EXISTING_CLUSTER

if [[ -z ${DOCKER_REPO_OVERRIDE} ]]; then
  export DOCKER_REPO_OVERRIDE=gcr.io/$(gcloud config get-value project)
fi
readonly ELA_DOCKER_REPO=${DOCKER_REPO_OVERRIDE}

# Build and start Elafros.

echo "================================================="
echo "* Cluster is ${K8S_CLUSTER_OVERRIDE}"
echo "* User is ${K8S_USER_OVERRIDE}"
echo "* Docker is ${DOCKER_REPO_OVERRIDE}"

header "Building and starting Elafros"
trap teardown EXIT

# --expunge is a workaround for https://github.com/elafros/elafros/issues/366
bazel clean --expunge
if (( USING_EXISTING_CLUSTER )); then
  echo "Deleting any previous Elafros instance"
  bazel run //:everything.delete  # ignore if not running
fi
if (( IS_PROW )); then
  echo "Authenticating to GCR"
  # kubekins-e2e images lack docker-credential-gcr, install it manually.
  # TODO(adrcunha): Remove this step once docker-credential-gcr is available.
  gcloud components install docker-credential-gcr
  docker-credential-gcr configure-docker
  echo "Successfully authenticated"
fi

bazel run //:everything.apply
wait_for_elafros || exit 1

# Enable Istio sidecar injection
bazel run @istio_release//:webhook-create-signed-cert
kubectl label namespace default istio-injection=enabled

# Run the tests

run_hello_world
exit_if_test_failed
#run_conformance_tests
#exit_if_test_failed

# kubetest teardown might fail and thus incorrectly report failure of the
# script, even if the tests pass.
# We store the real test result to return it later, ignoring any teardown
# failure in kubetest.
# TODO(adrcunha): Get rid of this workaround.
echo -n "0"> ${TEST_RESULT_FILE}
exit 0