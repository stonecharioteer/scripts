#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
GITIGNORE_DIR="$HOME/code/tools/gitignore"
[ -d "$GITIGNORE_DIR" ] || git clone git@github.com:github/gitignore.git "$GITIGNORE_DIR"
cd "$GITIGNORE_DIR"
gum style \
	--foreground 212 --border-foreground 212 --border double \
	--align center --width 50 --margin "1 2" --padding "2 4" \
	'.gitignore Selector' 'Select gitignore templates to add to .gitignore'
SELECTED=$(find . -type f -name "*.gitignore" | sed 's|^\./||' | sort -u | gum filter --no-limit --placeholder 'Select .gitignore template(s)' --header ".gitignore Selector" --header.foreground='212' --header.background='0' --header.bold --height 10)

cd - >/dev/null

for FILE in $SELECTED; do
  {
    echo ""
    echo "# from github.com/github/gitignore - $FILE"
    cat "$GITIGNORE_DIR/$FILE"
  } >> .gitignore
done

