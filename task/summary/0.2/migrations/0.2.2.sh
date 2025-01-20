#!/usr/bin/env bash

set -e

declare -r pipeline_file=$1

# TODO: add params:
#   params:
#   - name: IMAGE
#     value: $(tasks.build-image-index.results.IMAGE_URL)

declare -r bundle_ref=quay.io/mytestworkload/task-apply-tags:0.1@sha256:c72d34ffb01a9340ed3783483945d0c497da194a8e2443fa338671b94a252031

yq -i "
.spec.tasks += {
    \"name\": \"apply-tags\",
    \"runAfter\": [\"build-container\"],
    \"taskRef\": {
        \"resolver\": \"bundles\",
        \"params\": [
            {\"name\": \"name\", \"value\": \"apply-tags\"},
            {\"name\": \"kind\", \"value\": \"task\"},
            {\"name\": \"bundle\", \"value\": \"${bundle_ref}\"}
        ]
    }
}
" \
"$pipeline_file"

