#!/usr/bin/env bash
# Print the configured external project-context pointer block for one project.
#
# Usage: fm-project-context.sh <project-name>
#
# Reads the local, gitignored config/project-context-links file from the active
# firstmate home. Each non-empty, non-comment line is
# "<project-name><TAB><absolute-root>".
#
# When the named project has a configured match, prints a Markdown section that
# points firstmate or a worker at the authoritative external context root before
# scoping or operating. It requires the matched root to resolve to a directory
# containing AGENTS.md and .pi/skills/.
#
# When the file is absent or the project is not listed, prints nothing and exits
# 0 so unconfigured projects keep their existing behavior.
#
# A malformed matching line, a non-absolute root, a duplicate matching project,
# or a matched root missing AGENTS.md or .pi/skills/ is refused loudly rather
# than silently dropping the pointer.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
  CONFIG=$(resolve_directory_input FM_CONFIG_OVERRIDE "$FM_CONFIG_OVERRIDE") || exit 1
else
  CONFIG="$FM_HOME/config"
fi
LINKS_FILE="$CONFIG/project-context-links"
PROJECT=${1:?usage: fm-project-context.sh <project-name>}

[ -f "$LINKS_FILE" ] || exit 0

match_root=
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  case "$line" in
    ''|'#'*) continue ;;
  esac
  case "$line" in
    *$'\t'*)
      project=${line%%$'\t'*}
      root=${line#*$'\t'}
      ;;
    *) die "$LINKS_FILE:$line_no: expected <project-name><TAB><absolute-root>" ;;
  esac
  [ -n "$project" ] || die "$LINKS_FILE:$line_no: project name is empty"
  [ -n "$root" ] || die "$LINKS_FILE:$line_no: absolute root is empty"
  case "$root" in
    /*) ;;
    *) die "$LINKS_FILE:$line_no: root for $project must be absolute: $root" ;;
  esac
  [ "$project" = "$PROJECT" ] || continue
  [ -z "$match_root" ] || die "$LINKS_FILE:$line_no: duplicate project entry for $PROJECT"
  match_root=$root
done < "$LINKS_FILE"

[ -n "$match_root" ] || exit 0

context_root=$(CDPATH='' cd -- "$match_root" 2>/dev/null && pwd -P) \
  || die "$LINKS_FILE: configured root for $PROJECT cannot be resolved: $match_root"
agents_path="$context_root/AGENTS.md"
skills_path="$context_root/.pi/skills"
guide_path="$context_root/Homelab_Reference_and_Troubleshooting_Guide.md"

[ -f "$agents_path" ] || die "$LINKS_FILE: configured root for $PROJECT is missing AGENTS.md: $agents_path"
[ -d "$skills_path" ] || die "$LINKS_FILE: configured root for $PROJECT is missing .pi/skills: $skills_path"

cat <<EOF
# External project context
This project has configured authoritative context outside this worktree, so do not rely on path ancestry to rediscover it.
Before scoping or operating, read \`$agents_path\`.
Load the matching subsystem skill from \`$skills_path/\` before work; the parent \`AGENTS.md\` owns which skill matches the task.
EOF
if [ -f "$guide_path" ]; then
  printf 'Use `%s` for broader troubleshooting context.\n' "$guide_path"
fi
cat <<'EOF'
Keep the repo's own `README.md` and project docs in this worktree authoritative for repo-local architecture, manifests, and commands.
EOF
