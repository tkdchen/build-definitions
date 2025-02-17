#!/usr/bin/env bash

set -euo pipefail

# This test requires:
# 1) a clean image repository
# 2) checkout to a new branch inside build-definitions repo.
#
# For the test points, please refer to each step info line below.

t_info() {
    echo "info: 🍋 $1"
}

: "${TEST_IMAGE_REPO:=quay.io/mytestworkload/build-definitions-bundles-test-builds}"
t_info "using image repository $TEST_IMAGE_REPO"

declare -r TASK_BUNDLE_LIST=/tmp/test-task-bundles-list
declare -r IMAGE_MANIFEST_FILE=/tmp/test-task-migrations-image-manifest.json

declare -r ANNOTATION_HAS_MIGRATION="dev.konflux-ci.task.has-migration"
declare -r ANNOTATION_PREVIOUS_MIGRATION_BUNDLE="dev.konflux-ci.task.previous-migration-bundle"

declare -r TASK_NAME=push-dockerfile
declare -r TASK_VERSION=0.1
declare -r TASK_FILE="task/${TASK_NAME}/${TASK_VERSION}/${TASK_NAME}.yaml"


t_fail() {
    echo "fail: $1" >&2
    exit 2
}

t_succeed() {
    echo "ok: $1"
}

build_and_push() {
    local image_repo=${TEST_IMAGE_REPO#*/}  # remove registry
    rm -f "$TASK_BUNDLE_LIST"
    QUAY_NAMESPACE="${image_repo%/*}" \
    TEST_REPO_NAME="${image_repo#*/}" \
    SKIP_BUILD=1 \
    OUTPUT_TASK_BUNDLE_LIST=${TASK_BUNDLE_LIST} \
    TEST_TASKS="push-dockerfile " \
        ./hack/build-and-push.sh
}

bump_task_version() {
    local -r task_file=$1
    local patch
    local new_version

    IFS=. read -r major minor patch < <(
        yq '.metadata.labels."app.kubernetes.io/version"' "$task_file"
    )
    patch=$((patch+1))
    new_version="${major}.${minor}.${patch}"
    # app.kubernetes.io/version: "0.3.1"
    sed -i "s|^\( \+app\.kubernetes\.io/version\): .\+$|\1: \"${new_version}\"|" "$task_file"
    echo "$new_version"
}

# Require build_and_push to run firstly. The bundle reference including digest is output to stdout.
get_task_pushdocker_bundle_ref() {
    if ! grep "\(task-\)\?${TASK_NAME}" "$TASK_BUNDLE_LIST" 2>/dev/null; then
        echo "fail: cannot find task bundle for $TASK_NAME" >&2
        exit 1
    fi
}

fetch_push_dockerfile_image_manifest() {
    local bundle_ref
    bundle_ref=$(get_task_pushdocker_bundle_ref)
    skopeo inspect --raw "docker://$(remove_tag "$bundle_ref")" >"$IMAGE_MANIFEST_FILE"
}

bump_task_version_and_commit() {
    bump_task_version "$TASK_FILE"
    git add "$TASK_FILE"
    git commit -m "bump version of task $TASK_NAME"
}

remove_tag() {
    local ref=$1
    local digest=${ref#*@}
    ref=${ref%@*}  # remove digest
    ref=${ref%:*}  # remove tag
    echo "${ref}@${digest}"
}

create_migration() {
    local -r task_file=$1
    local -r new_version=$2
    local -r versioned_dir=${task_file%/*}
    local -r filename=${task_file##*/}

    local -r migration_dir="${versioned_dir}/migrations"
    [ -e "$migration_dir" ] || mkdir -p "$migration_dir"

    local -r migration_file="${migration_dir}/${new_version}.sh"

    cat >"$migration_file" <<EOF
#!/usr/bin/env bash

set -euo pipefail

# Migration for task ${filename%.*} created by Konflux
# Creation time: $(date --rfc-3339=seconds --utc)

declare -r pipeline_file=\${1:Missing pipeline file}

# Note: migration must make changes in place of the given pipeline file.

# migration code here...
#
EOF
    echo "$migration_file"
}

update_task_with_migration() {
    local new_version migration_file
    new_version=$(bump_task_version "$TASK_FILE")
    migration_file=$(create_migration "$TASK_FILE" "$new_version")
    git add "$TASK_FILE" "$migration_file"
    git commit -m "Create a migration for task $TASK_NAME"
    build_and_push
}


#####################  Tests start ##############################

t_info ""
t_info "Step 0, initial build and push"

# Initial task and pipeline bundles push as baseline
build_and_push

fetch_push_dockerfile_image_manifest

bundle_ref=$(get_task_pushdocker_bundle_ref)
if jq -e ".annotations | has(\"${ANNOTATION_HAS_MIGRATION}\")" >/dev/null <"$IMAGE_MANIFEST_FILE"; then
    t_fail "task bundle $bundle_ref should not have annotation $ANNOTATION_HAS_MIGRATION"
fi


# Step 1
#
t_info ""
t_info "Step 1, first time to update task without a migration"

bump_task_version_and_commit
build_and_push

# Verify
set -e
fetch_push_dockerfile_image_manifest

bundle_ref=$(get_task_pushdocker_bundle_ref)
set +e
t_info "new bundle $bundle_ref"

if jq -e ".annotations | has(\"${ANNOTATION_HAS_MIGRATION}\")" >/dev/null <"$IMAGE_MANIFEST_FILE"; then
    t_fail "task bundle $bundle_ref should not have annotation $ANNOTATION_HAS_MIGRATION"
fi
value=$(jq -e -r ".annotations.\"${ANNOTATION_PREVIOUS_MIGRATION_BUNDLE}\"" <"$IMAGE_MANIFEST_FILE")
if [ -n "$value" ]; then
    t_fail "task bundle $bundle_ref should not have annotation $ANNOTATION_PREVIOUS_MIGRATION_BUNDLE with $value"
fi

unset bundle_ref

# Step 2: create a migration for task push-dockerfile
t_info ""
t_info "Step 2: create a migration for task push-dockerfile"

update_task_with_migration

# Verify
fetch_push_dockerfile_image_manifest

bundle_ref=$(get_task_pushdocker_bundle_ref)
t_info "new bundle $bundle_ref"

bundle_with_migration="${bundle_ref}"  # save for later assertion below
t_info "bundle $bundle_with_migration has a migration."

if jq -e ".annotations | has(\"${ANNOTATION_HAS_MIGRATION}\") | not" >/dev/null <"$IMAGE_MANIFEST_FILE"; then
    t_fail "task bundle $bundle_ref does not have annotation $ANNOTATION_HAS_MIGRATION"
fi
value=$(jq -e -r ".annotations.\"${ANNOTATION_PREVIOUS_MIGRATION_BUNDLE}\"" <"$IMAGE_MANIFEST_FILE")
if [ -n "$value" ]; then
    t_fail "task bundle $bundle_ref is the first one with a migraiton, then it should not have annotation $ANNOTATION_PREVIOUS_MIGRATION_BUNDLE with $value"
fi

unset bundle_ref

# Step 3: make change to push-dockerfile, no migration, the bundle points to previous one by the annotation, which has a migration.
t_info ""
t_info "Step 3: make change to push-dockerfile, no migration, the bundle points to previous one by the annotation, which has a migration"

check_task_update_without_migration() {
    local -r expected_bundle_digest=$1
    local bundle_ref

    bump_task_version_and_commit
    build_and_push

    fetch_push_dockerfile_image_manifest
    bundle_ref=$(get_task_pushdocker_bundle_ref)
    t_info "new bundle $bundle_ref"

    if jq -e ".annotations | has(\"${ANNOTATION_HAS_MIGRATION}\")" >/dev/null <"$IMAGE_MANIFEST_FILE"; then
        t_fail "task bundle $bundle_ref does not a migration and should not have annotation $ANNOTATION_HAS_MIGRATION"
    fi
    value=$(jq -e -r ".annotations.\"${ANNOTATION_PREVIOUS_MIGRATION_BUNDLE}\"" <"$IMAGE_MANIFEST_FILE")
    if [ "$value" != "$expected_bundle_digest" ]; then
        t_fail "task bundle $bundle_ref should point to previous bundle $bundle_with_migration, but annotation $ANNOTATION_PREVIOUS_MIGRATION_BUNDLE has $value"
    fi
}

check_task_update_without_migration "${bundle_with_migration#*@}"
check_task_update_without_migration "${bundle_with_migration#*@}"

# Step 4: update task with a new migration. New bundle should still points to the previous bundle that has migration.
t_info ""
t_info "Step 4: update task with a new migration. New bundle should still points to the previous bundle that has migration"

update_task_with_migration

# Verify
fetch_push_dockerfile_image_manifest

bundle_ref=$(get_task_pushdocker_bundle_ref)
t_info "new bundle $bundle_ref"

new_bundle_with_migration="${bundle_ref}"  # save for later assertion below
t_info "bundle $new_bundle_with_migration has a migration."

if jq -e ".annotations | has(\"${ANNOTATION_HAS_MIGRATION}\") | not" >/dev/null <"$IMAGE_MANIFEST_FILE"; then
    t_fail "task bundle $bundle_ref does not have annotation $ANNOTATION_HAS_MIGRATION"
fi
value=$(jq -e -r ".annotations.\"${ANNOTATION_PREVIOUS_MIGRATION_BUNDLE}\"" <"$IMAGE_MANIFEST_FILE")
if [ "$value" != "${bundle_with_migration#*@}" ]; then
    t_fail "task bundle $bundle_ref is the second one that has a migraiton, but it does not point to previous bundle $bundle_with_migration, instead it has annotation $ANNOTATION_PREVIOUS_MIGRATION_BUNDLE with $value"
fi

bundle_with_migration="$new_bundle_with_migration"
unset new_bundle_with_migration

# Step 5: update task without a migration, it points to the previous bundle created in step 4
t_info "step 5: update task without a migration, it points to the previous bundle created in step 4"

check_task_update_without_migration "${bundle_with_migration#*@}"

########################### Tests end #######################################

t_info ""
t_info ""

declare -r params="onlyActiveTags=true&filter_tag_name=like:${TASK_NAME}-${TASK_VERSION}-"
curl -sL "https://quay.io/api/v1/repository/${TEST_IMAGE_REPO#*/}/tag/?${params}" | \
jq -r '.tags[] | .name + " " + .manifest_digest' | \
while read -r tag_name manifest_digest; do
    echo "🎯 ${TEST_IMAGE_REPO}:${tag_name}@${manifest_digest}"
    manifest_json=$(skopeo inspect --raw "docker://${TEST_IMAGE_REPO}@${manifest_digest}")
    if jq -e ".annotations | has(\"${ANNOTATION_HAS_MIGRATION}\")" >/dev/null <<<"$manifest_json"; then
        echo "    Has migration ✅"
    else
        echo "    Has migration 🈚"
    fi
    if value=$(jq -e -r ".annotations.\"${ANNOTATION_PREVIOUS_MIGRATION_BUNDLE}\"" <<<"$manifest_json"); then
        echo "    Prev migration: $value"
    fi
done
