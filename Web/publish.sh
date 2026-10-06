#!/bin/zsh
# Builds the web player and puts it on the web: the site is pushed to this repository's gh-pages
# branch, which GitHub Pages serves (for github.com/NAME/siday, at https://NAME.github.io/siday/).
#
#   ./publish.sh
#
# The branch holds the site as built and nothing else, in a single commit that each publishing
# replaces: built files do not pile up in the repository, and the branch has no history to keep.
# Nothing is published by pushing to main; the page changes when this is run.
set -e
cd ${0:h}
package=${PWD:h}

remote=$(git -C $package remote get-url origin)
source=$(git -C $package rev-parse --short HEAD)
# What is published is what is here, committed or not: say so if the two differ.
[[ -z "$(git -C $package status --porcelain -- Web Sources Package.swift)" ]] || source="$source, with changes not yet committed"

./build.sh

site=$(mktemp -d)
trap 'rm -rf $site' EXIT
cp index.html style.css siday.js engine.js worklet.js $site/
mkdir $site/generated
cp generated/SidayWeb.wasm generated/SidayWebAudio.wasm generated/instantiate.js generated/runtime.js generated/bridge-js.js $site/generated/
# GitHub Pages is not to run the site through Jekyll: these are the files, as they are.
touch $site/.nojekyll

# The commit is made in the name this repository commits in, not whatever this Mac uses elsewhere.
name=$(git -C $package config user.name)
email=$(git -C $package config user.email)
git -C $site init --quiet --initial-branch gh-pages
git -C $site add --all
git -C $site -c user.name="$name" -c user.email="$email" commit --quiet --message "The web player, built from $source"
git -C $site push --force --quiet $remote gh-pages

page=$(print -r -- $remote | sed -E 's#^(git@github\.com:|https://github\.com/)([^/]+)/([^/.]+)(\.git)?$#https://\2.github.io/\3/#')
print "Published. GitHub takes a minute or two to put it up: $page"
