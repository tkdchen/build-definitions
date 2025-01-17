#!/usr/bin/env bash

pipeline_file=$1

yq -i \
"(.spec.tasks[] | select(.name == \"clone-repository\") | .params) |= [
    {\"name\": \"url\", \"value\": \"\$(params.git-url)\"},
    {\"name\": \"revision\", \"value\": \"\$(params.revision)\"}
]" \
"$pipeline_file"
