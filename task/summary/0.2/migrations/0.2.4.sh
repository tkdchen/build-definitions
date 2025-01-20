#!/usr/bin/env bash
set -e
pipeline_file="$1"
yq -i ".spec.params += [
    {\"name\": \"git-url\", \"type\": \"string\"},
    {\"name\": \"revision\", \"type\": \"string\"},
    {\"name\": \"output-image\", \"type\": \"string\"}
]
" "$pipeline_file"
