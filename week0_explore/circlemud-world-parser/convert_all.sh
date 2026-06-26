#!/bin/sh
# Usage: ./convert_all.sh <input_dir> [output_dir]
#   input_dir   directory containing CircleMUD world files (required)
#   output_dir  where JSON is written, default: _output
input_dir=$1
output_dir=${2:-_output}

if [ -z "$input_dir" ]; then
    echo "Usage: $0 <input_dir> [output_dir]" >&2
    exit 1
fi

for type in "mob" "obj" "shp" "wld" "zon"; do
    # make the empty folder
    mkdir -p "$output_dir/$type"

    # get the filenames for each file type
    files=$( find "$input_dir" -name "*.$type" )

    # convert the files
    for file in $files; do
        filename=$(basename -- "$file")
        number=${filename%%.*}
        output="$output_dir/$type/$number.json"
        echo parsing $file to $output
        uv run circlemud-parse --dest "$output" "$file"
    done
done
