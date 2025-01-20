#!/usr/bin/env bash
set -e
pipeline_file="$1"
yq -i "del(.spec.tasks[] | select(.name == \"greeting\"))" "$pipeline_file"
