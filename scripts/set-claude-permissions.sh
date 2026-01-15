#!/bin/bash

set_readonly_permissions() {
  # How it works:
  # - -s (slurp): reads all inputs into an array
  # - .[0]: the original file content
  # - .[1]: the heredoc JSON from stdin (-)
  # - *: recursive merge (right side overrides left)

  # others:
  # // External web access
  # "WebFetch(**)",
  # "WebSearch(**)",
  local updated_settings=$(jq -s '.[0] * .[1]' ~/.claude/settings.json - <<EOF
{
    "permissions": {
        "allow": [
            "ReadFile(**)",
            "NotebookRead(**)",
            "LS(**)",
            "Glob(**)",
            "Find(**)",
            "Search(**)",
            "Grep(**)",
            "Agent",
            "Bash(grep:*)",
            "Bash(grep -R:*)",
            "Bash(rg:*)",
            "Bash(ripgrep:*)",
            "Bash(cat:*)",
            "Bash(head:*)",
            "Bash(tail:*)",
            "Bash(less:*)",
            "Bash(awk:*)",
            "Bash(sed -n:*)",
            "Bash(wc:*)",
            "Bash(sort:*)",
            "Bash(uniq:*)",
            "Bash(find:*)",
            "Bash(ls:*)",
            "Bash(tree:*)",
            "Bash(git diff:*)",
            "Bash(git show:*)",
            "Bash(git log:*)"
        ]
    }
}
EOF
)
  echo "${updated_settings}" | tee ~/.claude/settings.json
}

set_readonly_permissions
