#!/usr/bin/env bash

pipeline_file=$1

yq -i '(.spec.tasks[] | select(.name == "build-container") | .runAfter) |= ["clone-repository"]' "$pipeline_file"
