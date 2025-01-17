#!/usr/bin/env bash

pipeline_file=$1

yq -i '(.spec.tasks[] | select(.name == "summary") | .runAfter) |= ["build-container"]' "$pipeline_file"