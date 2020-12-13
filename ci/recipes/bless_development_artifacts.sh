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
declare -rx ORIGIN_ENVIRONMENT="${ORIGIN_ENVIRONMENT:-dev}"
declare -rx ORIGIN_REPOSITORY="${ORIGIN_REPOSITORY:-brdevregistry}"
declare -rx RELEASE_PREFIX="${RELEASE_PREFIX:-r}"
declare -rx DEFAULT_SEMVER="${DEFAULT_SEMVER:-0.0.0}"
declare -rx BUMP_SEMVER="${BUMP_SEMVER:-true}"
declare -rx BUILD_REPOSITORY_LOCALPATH="${BUILD_REPOSITORY_LOCALPATH:-.}"
declare -rx IMAGENAME="${IMAGENAME:-br-oauth-proxy-docker}"
declare -rx TAG="${TAG:-bedrock}"
declare -rx TF_BUILD="${TF_BUILD:-}"
declare -rx BUILD_SOURCEBRANCHNAME="${BUILD_SOURCEBRANCHNAME:-}"

# Arguments
# ---------------------

function repo_root () {
    git rev-parse --show-toplevel
}

function is_azure_pipeline_build () {
    [[ "True" == "${TF_BUILD:-}" ]]
}

function acr_login () {
    local -r desired_repo="${1}"
    if ! is_azure_pipeline_build; then
        az acr login -n "${desired_repo}" 2> /dev/null
    fi
}

function current_repo_branch () {
    git status -b  | grep "^On branch" | sed -e 's/.* //'
}

function release_prefix () {
    printf '%s' "${RELEASE_PREFIX}"
}

function release_prefix_glob () {
    printf '%s*' "$(release_prefix)"
}

function release_prefix_remove_expr () {
    printf 's/^%s//' "$(release_prefix)"
}

function current_repo_version () {
    git describe --match "$(release_prefix_glob)" --abbrev=0 2> /dev/null || true
}

function remove_release_prefix () {
    sed -e "$(release_prefix_remove_expr)"
}

function extract_semver () {
    cut -d '+' -f 1 | cut -d '-' -f 1 | remove_release_prefix
}

function extract_semver_major () {
    cut -d '.' -f 1
}

function extract_semver_minor () {
    cut -d '.' -f 2
}

function extract_semver_patch () {
    cut -d '.' -f 3
}

function extract_semver_build () {
    cut -d '+' -f 2 -s
}

function extract_semver_prerelease () {
    cut -d '+' -f 1 | cut -d '-' -f 2 -s
}

function current_repo_semver () {
    # see https://semver.org
    current_repo_version | extract_semver
}

function current_repo_build () {
    # see https://semver.org
    current_repo_version | extract_semver_build
}

function current_repo_prerelease () {
    # see https://semver.org
    current_repo_version | extract_semver_prerelease
}

function default_repo_semver () {
    local current_semver
    current_semver="$(current_repo_semver)"
    if [[ -z "${current_semver:-}" ]]; then
        current_semver="${DEFAULT_SEMVER}"
    fi
    printf '%s' "${current_semver}"
}

function bump_repo_semver () {
    local current_semver="${1}"
    if [[ "true" == "${BUMP_SEMVER}" ]]; then
        local major minor patch
        major="$(extract_semver_major <<< "${current_semver}")"
        minor="$(extract_semver_minor <<< "${current_semver}")"
        patch="$(extract_semver_patch <<< "${current_semver}")"
        (( patch++ ))
        current_semver="${major}.${minor}.${patch}"
    fi
    printf '%s' "${current_semver}"
}

function new_repo_semver () {
    local current_semver
    current_semver="$( bump_repo_semver "$(default_repo_semver)" )"
    printf '%s' "${current_semver}"
}

function internal_semver_file () {
    printf '%s/semver.txt' "$(repo_root)"
}

function internal_semver_file_json () {
    yq r "$(internal_semver_file)" --tojson
}

function internal_repo_semver () {
    jq -r '.semver' <(internal_semver_file_json)
}

function compute_blessed_release_semver () {
    sort -t. -k 1,1nr -k 2,2nr -k 3,3nr <(new_repo_semver) <(internal_repo_semver) | head -1
}

function compute_blessed_release_tag () {
    local new_tag
    new_tag="$(compute_blessed_release_semver)"
    prerelease="dev"
    if ! is_azure_pipeline_build; then
        prerelease="${prerelease}.private"
    fi
    printf '%s%s-%s' "$(release_prefix)" "${new_tag}" "${prerelease}"
}

function origin_environment () {
    printf '%s' "${ORIGIN_ENVIRONMENT}"
}

function origin_repository () {
    printf '%s' "${ORIGIN_REPOSITORY}"
}

function target_path_with_new_tag () {
    local -r new_tag="${1}"
    sed -e 's/:.*//' \
        -e "s/$/:${new_tag}/" \
        -e "s:^[^/]*/\(.*\):$(target_repository).azurecr.io/\1:"
}

function update_git_config () {
    if is_azure_pipeline_build; then
        # configure azure pipeline workspace
        git config --global user.email "azure_automation@bytelight.com"
        git config --global user.name "Azure automation Blessing Artifacts from [$(origin_environment)]"
    fi
}

function current_branch () {
    local branch
    if is_azure_pipeline_build; then
        branch="${BUILD_SOURCEBRANCHNAME}"
    else
        branch="$(git rev-parse --abbrev-ref HEAD)"
    fi
    printf "%s" "${branch}"
}

function pending_git_files () {
    git status -s | grep -q '^M'
}

function update_internal_repo_semver () {
    local -r blessed_release_semver="${1}"
    local -r temp_file="$(mktemp)"
    internal_semver_file_json \
        | jq -r --arg new_semver "${blessed_release_semver}" '.semver = $new_semver' \
        | yq r - > "${temp_file}"
    cp "${temp_file}" "$(internal_semver_file)"
    rm -f "${temp_file}"
    git add "$(internal_semver_file)"
    if pending_git_files; then
        git commit -m "automated update of semver on git commit" || true
        git push origin HEAD:"$(current_branch)"
    fi
}

function update_git_tag () {
    local -r blessed_release_tag="${1}"
    if [[ "true" == "${BUMP_SEMVER}" ]]; then
        git tag -a "${blessed_release_tag}" -m "automated promotion on git commit"
        git push origin "${blessed_release_tag}"
    fi
}

function bless_git_repo () {
    local -r blessed_release_tag="${1}"
    update_git_config
    update_internal_repo_semver "$(extract_semver <<<"${blessed_release_tag}")"
    update_git_tag "${blessed_release_tag}"
}

function registry_image_name () {
    local -r tag="${1}"
    printf '%s.azurecr.io/%s:%s' "$(origin_repository)" "${IMAGENAME}" "${tag}"
}

function desired_image_exists () {
    local -r tag="${1}"
    printf 'desired_image_exists %s\n' "${tag}"
    acr_login "${ORIGIN_REPOSITORY}"
    docker pull "$(registry_image_name "${tag}")" 2> /dev/null
}

function bless_container () {
    local -r blessed_tag="${1}"
    local origin_container result_container
    origin_container="$(registry_image_name "${TAG}" )"
    result_container="$(registry_image_name "${blessed_tag}" )"
    docker tag "${origin_container}" "${result_container}"
    docker push "${result_container}" 1>&2
}

function update_docker_container () {
    local -r blessed_release_tag="${1}"
    printf 'update_docker_container %s\n' "${blessed_release_tag}"
    if ! desired_image_exists "${blessed_release_tag}"; then
        bless_container "${blessed_release_tag}"
    fi
}

function update_chart_yaml () {
    local -r chartDir="${1}"
    local -r blessed_release_tag="${2}"
    local chartFile
    local -r temp_file="$(mktemp)"
    chartFile="${chartDir}/Chart.yaml"
    sed -e "s|^appVersion:.*|appVersion: '${blessed_release_tag}'|" \
        -e "s|^version:.*|version: $(remove_release_prefix <<< "${blessed_release_tag}")|" \
        "${chartFile}" \
        > "${temp_file}"
    cp "${temp_file}" "${chartFile}"
    rm "${temp_file}"
    git add "${chartFile}"
}

function build_and_push_helm_chart () {
    local -r chartDir="${1}"
    local -r blessed_release_tag="${2}"
    local chartPackage
    chartPackage="${IMAGENAME}-$(remove_release_prefix <<< "${blessed_release_tag}").tgz"
    rm -f "${chartDir}/Chart.lock"
    helm dependency build "${chartDir}"
    git add "${chartDir}/Chart.lock" || true
    helm package "${chartDir}"
    az acr helm push -n "$(origin_repository)" "${chartPackage}"
    rm -f "${chartPackage}"
}

function update_helm_chart () {
    local -r blessed_release_tag="${1}"
    printf 'update_helm_chart %s\n' "${blessed_release_tag}"
    local chartDir
    chartDir="$(repo_root)/helm/${IMAGENAME}"
    update_chart_yaml "${chartDir}" "${blessed_release_tag}"
    build_and_push_helm_chart "${chartDir}" "${blessed_release_tag}"
}

function warn_nothing_done () {
    printf 'Did not update docker container or helm chart\n'
    printf '  If this is not what you intended, did you update the semver.txt or git tag?\n'
}

function install_yq_if_needed () {
    if ! command -v yq; then
        sudo add-apt-repository ppa:rmescandon/yq > /dev/null
        sudo apt update > /dev/null
        sudo apt install yq -y > /dev/null
    fi
}

function update_docker_helm_git () {
    local -r blessed_release_tag="$(compute_blessed_release_tag)"
    if update_docker_container "${blessed_release_tag}" ; then
        if update_helm_chart "${blessed_release_tag}"; then
            bless_git_repo "${blessed_release_tag}"
        fi
    else
        warn_nothing_done
    fi
}

function dump_env () {
    set -o xtrace
        helm version
        az version
        yq --version
        jq --version
        env
    set +o xtrace
}

function bless_development_artifacts () {
    pushd "${BUILD_REPOSITORY_LOCALPATH}"
    pwd
        install_yq_if_needed
        dump_env
        update_docker_helm_git
    popd
}

bless_development_artifacts
