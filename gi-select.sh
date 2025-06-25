#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
# Print out the script title
gum style \
	--foreground 212 --border-foreground 212 --border double \
	--align center --width 50 --margin "1 2" --padding "2 4" \
	'.gitignore Selector' 'Select gitignore templates to add to .gitignore'
GITIGNORE_DIR="$HOME/code/tools/gitignore"
# create the folder if it doesn't exist
mkdir -p "$GITIGNORE_DIR"
# Check if git@github.com:github/gitignore.git is cloned in ~/code/tools/gitignore
[ -d "$GITIGNORE_DIR" ] || git clone git@github.com:github/gitignore.git "$GITIGNORE_DIR"
pushd "$GITIGNORE_DIR" >/dev/null
SELECTED=$(find . -type f -name "*.gitignore" | sed 's|^\./||' | sort -u | gum filter --no-limit --placeholder 'Select .gitignore template(s)' --header ".gitignore Selector" --header.foreground='212' --header.background='0' --header.bold --height 10)
popd >/dev/null

while IFS= read -r FILE; do
	{
		echo ""
		echo "# from github.com/github/gitignore - $FILE"
		cat "$GITIGNORE_DIR/$FILE"
	} >>.gitignore
done <<<"$SELECTED"
