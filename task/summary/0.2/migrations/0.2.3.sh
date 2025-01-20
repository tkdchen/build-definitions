#!/usr/bin/env bash
set -e
pipeline_file="$1"
bundle_ref=quay.io/mytestworkload/task-greeting:0.1@sha256:f4e906691963f1bac6b6872e71b01224569d8dd587c2f3c886bebc328d6bb204
yq -i "
.spec.tasks += {
    \"name\": \"greeting\",
    \"taskRef\": {
        \"resolver\": \"bundles\",
        \"params\": [
            {\"name\": \"name\", \"value\": \"greeting\"},
            {\"name\": \"kind\", \"value\": \"task\"},
            {\"name\": \"bundle\", \"value\": \"${bundle_ref}\"}
        ]
    }
}
" \
"$pipeline_file"
