#!/usr/bin/env fish
# Bootstrap submodules for local development
# Behaviors improved:
# - fetch, checkout and pull use --ff-only to avoid unexpected merges
# - failures stop the script and are reported
set -l root (pwd)
echo "Initializing submodules..."
git submodule update --init --recursive
echo "Checking out tracked branches and pulling latest for each submodule..."
# Use git submodule foreach which runs the snippet in a shell inside each submodule.
# On failure we exit with non-zero so problems are visible to callers.
git submodule foreach 'branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo main); \
	echo "[$path] branch=$branch -> fetching..."; \
	git fetch origin "$branch" || { echo "[$path] git fetch failed"; exit 1; }; \
	git checkout "$branch" || { echo "[$path] git checkout $branch failed"; exit 1; }; \
	git pull --ff-only origin "$branch" || { echo "[$path] git pull --ff-only failed (non-fast-forward or remote changed)"; exit 1; }'
echo "Done."

# Ensure submodules declared in projects/*/package.json exist in .gitmodules; add them if missing
echo "Ensuring submodule entries from package.json are present..."
for pkg in projects/*/package.json
	if test -f "$pkg"
		# extract repository.url and repository.directory. Prefer jq (robust); fall back to sed.
		if type -q jq
			set repo_url (jq -r '.repository.url // .repository // ""' "$pkg")
			set repo_dir (jq -r '.repository.directory // ""' "$pkg")
		else
			# basic sed fallback: try to find "url" and "directory" values
			set repo_url (sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg" | head -n1)
			set repo_dir (sed -n 's/.*"directory"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg" | head -n1)
		end

		if test -z "$repo_url"
			# nothing to do for this package.json
			continue
		end

		# strip optional git+ prefix (e.g. git+https://...)
		set repo_url (string replace -r '^git\+' '' $repo_url)

		# Derive SSH/HTTPS variants; default preference via SUBMOD_PROTO (ssh|https), default ssh
		set -l proto (string lower -- $SUBMOD_PROTO)
		if test -z "$proto"
			set proto ssh
		end
		# Extract <owner>/<repo>.git from either https or ssh form
		set -l repo_path ""
		if string match -qr '^git@[^:]+:.+' -- $repo_url
			# git@host:owner/repo(.git)
			set repo_path (string replace -r '^[^:]*:' '' -- $repo_url)
		else if string match -qr '^https?://[^/]+/.+' -- $repo_url
			# https://host/owner/repo(.git)
			set repo_path (string replace -r '^https?://[^/]+/' '' -- $repo_url)
		else
			# fallback: assume already owner/repo(.git)
			set repo_path $repo_url
		end
		# ensure .git suffix exists
		if not string match -qr '\\.git$' -- $repo_path
			set repo_path "$repo_path.git"
		end
		# build URLs (assume github.com host)
		set -l https_url "https://github.com/$repo_path"
		set -l ssh_url "git@github.com:$repo_path"
		# choose desired url by proto
		set -l desired_url
		if test "$proto" = "ssh"
			set desired_url $ssh_url
		else
			set desired_url $https_url
		end

		# fall back to the package directory if repository.directory not provided
		if test -z "$repo_dir"
			set repo_dir (dirname "$pkg")
		end

		# check if .gitmodules exists and contains the path
		set has_entry 0
		if not test -f .gitmodules
			set has_entry 0
		else if grep -q "path = $repo_dir" .gitmodules >/dev/null 2>&1
			set has_entry 1
		else
			set has_entry 0
		end

		# normalize target url (already built as desired_url)

		# If .gitmodules has a different URL for this path, update it
		if test $has_entry -eq 1
			set gm_url (git config -f .gitmodules --get submodule."$repo_dir".url 2>/dev/null || echo "")
			set gm_norm (string replace -r '^git\+' '' $gm_url)
			if test -n "$gm_url"; and test "$gm_norm" != "$desired_url"
				echo ".gitmodules URL for '$repo_dir' is '$gm_url' but expected '$desired_url'"
				if test -z "$SKIP_GIT"
					echo "Updating .gitmodules for $repo_dir -> $desired_url"
					git submodule set-url "$repo_dir" "$desired_url" || { echo "Failed to update .gitmodules url for $repo_dir"; exit 1; }
					git submodule sync -- "$repo_dir" || { echo "Failed to sync submodule $repo_dir"; exit 1; }
				else
					echo "SKIP_GIT set; would run: git submodule set-url '$repo_dir' '$desired_url' && git submodule sync -- '$repo_dir'"
				end
			end
		end

		# If the submodule entry exists but the directory is missing, initialize it
		if test $has_entry -eq 1; and not test -d "$repo_dir"
			echo "Submodule directory '$repo_dir' missing; initializing..."
			if test -z "$SKIP_GIT"
				git submodule update --init -- "$repo_dir" || { echo "Failed to init submodule $repo_dir"; exit 1; }
			else
				echo "SKIP_GIT set; would run: git submodule update --init -- '$repo_dir'"
			end
		end

		# If the directory already exists, check its remote and update if necessary.
		if test -d "$repo_dir"
			# If it's a git repo (submodule can have .git file), ensure its origin matches the desired repo_url
			if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
				set current_url (git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "")
				# normalize by stripping leading git+ if present
				set current_norm (string replace -r '^git\+' '' $current_url)
				set desired_norm $desired_url
				if test "$current_norm" != "$desired_norm"
					echo "Remote origin for '$repo_dir' is '$current_url' but expected '$desired_url'"
					if test -z "$SKIP_GIT"
						echo "Updating remote origin for $repo_dir -> $desired_url"
						git -C "$repo_dir" remote set-url origin "$desired_url" || { echo "Failed to set remote for $repo_dir"; exit 1; }
					else
						echo "SKIP_GIT set; would run: git -C '$repo_dir' remote set-url origin '$desired_url'"
					end
				else
					echo "Remote origin for '$repo_dir' is correct."
				end
			else
				echo "Warning: path '$repo_dir' exists but is not a git repository; skipping."
			end
			# If not a submodule entry, warn the user
			if test $has_entry -eq 0
				echo "Warning: path '$repo_dir' exists but is not registered as a submodule; skipping automatic add. (Remove or move the directory and re-run if you want it added)"
			end
		else
			# dir doesn't exist
			if test $has_entry -eq 0
				echo "Would add submodule '$repo_dir' -> $desired_url"
				if test -z "$SKIP_GIT"
					echo "Adding submodule '$repo_dir' -> $desired_url"
					git submodule add "$desired_url" "$repo_dir" >/dev/null 2>&1; or begin; echo "git submodule add failed for $repo_dir"; exit 1; end
				else
					echo "SKIP_GIT set; skipping git submodule add for $repo_dir"
				end
			else
				echo "Submodule entry for '$repo_dir' already present."
			end
		end
	end
end
