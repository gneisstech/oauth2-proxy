#!/usr/bin/env bash
# usage: bless_development_artifacts.sh

# Exit script if you try to use an uninitialized variable.
set -o nounset

# Exit script if a statement returns a non-true return value.
set -o errexit

# Use the error status of the first failure, rather than that of the last item in a pipeline.
set -o pipefail

# Environment Variables
# ---------------------
declare -rx BUILD_REPOSITORY_LOCALPATH="${BUILD_REPOSITORY_LOCALPATH:-.}"
declare -rx IMAGENAME="${IMAGENAME:-cf-oauth-proxy-docker}"

# Arguments
# ---------------------


function repo_root () {
    git rev-parse --show-toplevel
}

function is_azure_pipeline_build () {
    [[ "True" == "${TF_BUILD:-}" ]]
}

function sast_helm () {
    helm lint "$(repo_root)/helm/${IMAGENAME}/"
}

function sast_shell () {
    true
}

function sast_docker () {
    true
}

function sast_ruby () {
    true
}

function sast () {
    pushd "${BUILD_REPOSITORY_LOCALPATH}"
    pwd
        sast_helm
        sast_shell
        sast_docker
        sast_ruby
    popd
}

sast
