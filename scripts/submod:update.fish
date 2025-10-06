#!/usr/bin/env fish
# Update submodules to latest remote tracked branch (improved safety)
# - uses --ff-only to avoid unexpected merges
# - exits on failure and reports which submodule failed
git submodule foreach 'branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo main); \
	echo "[$path] branch=$branch -> fetching..."; \
	git fetch origin "$branch" || { echo "[$path] git fetch failed"; exit 1; }; \
	git checkout "$branch" || { echo "[$path] git checkout failed"; exit 1; }; \
	git pull --ff-only origin "$branch" || { echo "[$path] git pull --ff-only failed"; exit 1; }'
echo "All submodules updated."
