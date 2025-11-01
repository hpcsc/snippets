#!/bin/bash

set -euo pipefail
shopt -s nullglob

# example folder structure:

# docs
# ├── context
# │   ├── article-1.md
# │   └── article-2.md
# ├── getting-started
# │   ├── article-3.md
# │   └── article-4.md
# └── how-to
#     ├── article-5.md
#     └── article-6.md

generate_collapsible_section() {
    local folder=$1
    local level=$2
    local indentation=$(printf "  %.0s" $(seq 0 ${level}))
    for f in ${folder}/*; do
        if [ -d "${f}" ]; then
            local section=$(basename ${f})
            local capitalised_section=$(echo "${section:0:1}" | tr '[:lower:]' '[:upper:]')$(echo "${section:1}" | sed 's/-/ /g')
    echo "${indentation}- <details>
${indentation}  <summary>${capitalised_section}</summary>

$(generate_collapsible_section ${f} $((level+1)))
${indentation}  </details>"
        else
            if [[ ${f} == *.md ]]; then
                local title=$(basename ${f%.*})
                if [ -s ${f} ]; then
                    read -r title < ${f}
                    title=$(echo "${title}" | sed 's/# //')
                fi

                echo "${indentation}- [${title}](${f})"
            fi
        fi
    done
}

generate_toc() {
    generate_collapsible_section ${1} 0
}

generate_readme() {
    cat <<EOF | tee ./README.md
# docs

## Table of Content

$(generate_toc ./docs)
EOF
}

generate_readme
