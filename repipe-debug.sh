#!/bin/bash

# spruce-merge-diff-file-blame
#
# Script for merging YAML files using Spruce, resolving dynamic placeholders,
# and tracking file-level blame based on YAML hierarchy.

set -ue

# Function to escape special characters for grep
escape_for_grep() {
    sed 's/[]\[^$.*/]/\\&/g' <<< "$1"
}

# Function to resolve params from environment or other sources
resolve_placeholders() {
    local line="$1"
    resolved_line="$line"

    # Resolve (( param "..." )) with environment variables or default values
    if [[ "$line" =~ \(\(.*param\ \"(.*)\"\ \)\) ]]; then
        param_name="${BASH_REMATCH[1]}"
        param_value="${!param_name:-UNDEFINED_PARAM_$param_name}"  # Fallback to undefined message
        resolved_line=$(sed -e "s/\(\( param \"$param_name\" \)\)/$param_value/g" <<< "$line")
    fi

    # Resolve (( grab <something> )) by looking it up from the merged YAML or other files
    if [[ "$line" =~ \(\(.*grab\ (.*)\ \)\) ]]; then
        grab_target="${BASH_REMATCH[1]}"
        # Logic to lookup the value for `grab_target`, for example from merged YAML.
        grab_value=$(grep -oP "$grab_target:\s*\K.*" merged_temp.yml || echo "UNDEFINED_GRAB_$grab_target")
        resolved_line=$(sed -e "s/\(\( grab $grab_target \)\)/$grab_value/g" <<< "$line")
    fi

    # Resolve (( concat ... )) by concatenating the values
    if [[ "$line" =~ \(\(.*concat\ (.*)\ \)\) ]]; then
        concat_targets="${BASH_REMATCH[1]}"
        concat_values=""
        for target in $concat_targets; do
            value=$(grep -oP "$target:\s*\K.*" merged_temp.yml || echo "$target")
            concat_values+="$value"
        done
        resolved_line=$(sed -e "s/\(\( concat $concat_targets \)\)/$concat_values/g" <<< "$line")
    fi

    echo "$resolved_line"
}

# Function to find the correct line number based on YAML hierarchy
find_hierarchical_line_number() {
    local file="$1"
    local key="$2"
    local value="$3"
    local current_indent=0
    local line_number=0
    local found_key=false
    local found_line=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number++))
        if [[ "$line" =~ ^([[:space:]]*)(.+)$ ]]; then
            local indent_level=${#BASH_REMATCH[1]}
            local content="${BASH_REMATCH[2]}"

            if [[ $indent_level -le $current_indent ]]; then
                found_key=false
            fi

            if [[ "$content" == "$key:"* ]]; then
                found_key=true
                current_indent=$indent_level
                found_line=$line_number
            elif $found_key && [[ "$content" == *"$value"* ]]; then
                echo "$found_line"
                return 0
            fi
        fi
    done < "$file"

    echo "$found_line"
}

# Function to merge YAML files using Spruce and track blame with hierarchical approach
spruce_merge_with_blame() {
    local output_file="$1"
    shift
    local files=("$@")

    local temp_merged=$(mktemp)
    local temp_resolved=$(mktemp)

    echo "Performing Spruce merge..."
    spruce merge "${files[@]}" > "$temp_merged"

    echo "Resolving placeholders..."
    {
        echo "# Debug: Input files: ${files[*]}"
        while IFS= read -r line; do
            # Skip comments and empty lines
            if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
                echo "$line"
                continue
            fi

            # Resolve any placeholders in the line
            resolved_line=$(resolve_placeholders "$line")

            # Determine blame by checking each input file for the resolved value
            if [[ "$resolved_line" =~ ^([[:space:]]*)(.+)$ ]]; then
                indent="${BASH_REMATCH[1]}"
                content="${BASH_REMATCH[2]}"
                if [[ "$content" =~ ^([a-zA-Z0-9_]+):(.*)$ ]]; then
                    key="${BASH_REMATCH[1]}"
                    value="${BASH_REMATCH[2]}"
                    escaped_key=$(escape_for_grep "$key")
                    escaped_value=$(escape_for_grep "$value")
                    found=false
                    for file in "${files[@]}"; do
                        if grep -q "^[[:space:]]*${escaped_key}:[[:space:]]*${escaped_value}" "$file"; then
                            line_number=$(find_hierarchical_line_number "$file" "$key" "$value")
                            if [[ -n "$line_number" ]]; then
                                echo "${indent}# File: $file (Line: $line_number)"
                                echo "$resolved_line"
                                found=true
                                break
                            fi
                        fi
                    done
                    if ! $found; then
                        echo "$resolved_line"
                        echo "Warning: Key-value pair '$key:$value' not found in any file" >&2
                    fi
                else
                    echo "$resolved_line"
                fi
            else
                echo "$resolved_line"
            fi
        done
    } < "$temp_merged" > "$output_file"

    echo "Final merged file with blame:"
    cat "$output_file"

    rm "$temp_merged" "$temp_resolved"
}

# Main script
main() {
    base_dir="$(cd "$(dirname "$0")" && pwd)"
    cd "$base_dir"

    # Prepare input files
    GLOBIGNORE="pipeline/custom*/*.yml:pipeline/optional*/*.yml"
    input_files=(pipeline/base.yml pipeline/*/*.yml settings.yml)
    unset GLOBIGNORE

    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 <output_merged.yml>"
        exit 1
    fi

    local merged_file="$1"

    echo "Merging input files using Spruce and tracking blame..."
    spruce_merge_with_blame "$merged_file" "${input_files[@]}"

    echo "Merged file with blame information has been saved to: $merged_file"
}

main "$@"
