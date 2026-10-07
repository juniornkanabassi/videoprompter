#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source env.sh
if git check-ignore --no-index Sources/VideoPrompter/Library/NewFile.swift Tests/PrompterCoreTests/Fixtures/Scripts/example.md; then
  print -u2 'Source or fixture is ignored'; exit 1
else
  [[ $? == 1 ]] || exit 1
fi
[[ -z "$(git ls-files --others --ignored --exclude-standard Sources Tests)" ]]
print 'Source ignore check passed.'
