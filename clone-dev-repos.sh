#!/usr/bin/env bash

set -u

usage() {
  cat <<'EOF'
Usage: clone-dev-repos.sh [--dry-run] [DEV_ROOT]

Clone this machine's Git repositories into the same relative paths under
DEV_ROOT. DEV_ROOT defaults to ~/dev. Existing Git repositories are skipped.

Examples:
  ./clone-dev-repos.sh
  ./clone-dev-repos.sh --dry-run
  ./clone-dev-repos.sh /Volumes/Work/dev
EOF
}

dry_run=false
dev_root="$HOME/dev"
dev_root_set=false

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -* )
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ "$dev_root_set" == true ]]; then
        printf 'Only one DEV_ROOT may be specified.\n' >&2
        exit 2
      fi
      dev_root=${1/#\~/$HOME}
      dev_root_set=true
      ;;
  esac
  shift
done

if ! command -v git >/dev/null 2>&1; then
  printf 'Git is required. Install the Xcode command line tools with: xcode-select --install\n' >&2
  exit 1
fi

if [[ "$dry_run" == false ]]; then
  mkdir -p "$dev_root" || exit 1
fi

cloned=0
skipped=0
blocked=0
failed=0

while IFS=$'\t' read -r relative_path remote_url; do
  [[ -n "$relative_path" ]] || continue
  target="$dev_root/$relative_path"

  if [[ -e "$target/.git" ]]; then
    printf 'SKIP    %s (already a Git repository)\n' "$target"
    (( skipped += 1 ))
    continue
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    printf 'BLOCKED %s (path exists but is not a Git repository)\n' "$target" >&2
    (( blocked += 1 ))
    continue
  fi

  if [[ "$dry_run" == true ]]; then
    printf 'CLONE   %s -> %s\n' "$remote_url" "$target"
    (( cloned += 1 ))
    continue
  fi

  mkdir -p "$(dirname "$target")"
  printf 'CLONE   %s -> %s\n' "$remote_url" "$target"
  if git clone -- "$remote_url" "$target"; then
    (( cloned += 1 ))
  else
    printf 'FAILED  %s\n' "$target" >&2
    (( failed += 1 ))
  fi
done <<'REPOSITORIES'
pretty-games/bussiness/docs	git@gitlab.com:pretty.games/bussiness/docs.git
pretty-games/bussiness/plan	git@gitlab.com:pretty.games/bussiness/plan.git
pretty-games/common	git@gitlab.com:pretty.games/common.git
pretty-games/decision-matrix	git@gitlab.com:pretty.games/decision-matrix.git
pretty-games/elemental-combat-league/backend	git@gitlab.com:pretty.games/elemental-combat-league/backend.git
pretty-games/elemental-combat-league/docs	git@gitlab.com:pretty.games/elemental-combat-league/docs.git
pretty-games/elemental-combat-league/frontend	git@gitlab.com:pretty.games/elemental-combat-league/frontend.git
pretty-games/guardians/memory-game	git@gitlab.com:pretty.games/guardians/memory-game.git
pretty-games/guardians/monster-creator	git@gitlab.com:pretty.games/guardians/monster-creator.git
pretty-games/ink-bound	git@gitlab.com:pretty.games/ink-bound.git
pretty-games/letter-tracing	git@gitlab.com:pretty.games/letter-tracing.git
pretty-games/memory-n-soundboard	git@gitlab.com:pretty.games/memory-n-soundboard.git
pretty-games/privacy-policy	git@gitlab.com:pretty.games/privacy-policy.git
pretty-games/productivity-planner	git@gitlab.com:pretty.games/productivity-planner.git
pretty-games/prototypes/computer-typing-game	git@gitlab.com:pretty.games/prototypes/computer-typing-game.git
pretty-games/prototypes/hex-tile-shape-puzzle	git@gitlab.com:pretty.games/prototypes/hex-tile-shape-puzzle.git
pretty-games/prototypes/monster-creator	git@gitlab.com:pretty.games/prototypes/monster-creator.git
pretty-games/prototypes/scan-quest	git@gitlab.com:pretty.games/prototypes/scan-quest.git
pretty-games/prototypes/text-adventure	git@gitlab.com:pretty.games/prototypes/text-adventure.git
pretty-games/prototypes/tools	git@gitlab.com:pretty.games/prototypes/tools.git
pretty-games/prototypes/unidos-gamejam-2025	git@gitlab.com:pretty.games/prototypes/unidos-gamejam-2025.git
pretty-games/space-adventure	git@gitlab.com:pretty.games/space-adventure.git
pretty-games/space-adventures/app	git@gitlab.com:pretty.games/space-adventures/app.git
pretty-games/tools/gitlab-runner	git@gitlab.com:pretty.games/tools/gitlab-runner.git
pretty-games/tools/screen-shooter	git@gitlab.com:pretty.games/tools/screen-shooter.git
pretty-games/travel-hunt/app	git@gitlab.com:pretty.games/travel-hunt/app.git
pretty-games/travel-hunt/tools	git@gitlab.com:pretty.games/travel-hunt/tools.git
pretty-games/websites/playtest-hub	git@gitlab.com:pretty.games/websites/playtest-hub.git
pretty-games/websites/www	git@gitlab.com:pretty.games/websites/www.git
tiagosomda/age-lapse	git@gitlab.com:tiagosomda/age-lapse.git
tiagosomda/cook-with-me	git@gitlab.com:tiagosomda/cook-with-me.git
tiagosomda/dev-loop	git@github.com:tiagosomda/loop.git
tiagosomda/home-hunters-app	git@gitlab.com:tiagosomda/home-hunters-app.git
tiagosomda/links.tiago.dev	git@github.com:tiagosomda/links.tiago.dev.git
tiagosomda/match-chat	git@github.com:tiagosomda/match-chat.git
tiagosomda/notes	git@github.com:tiagosomda/notes.git
tiagosomda/psytonics-self-guided-study	git@github.com:tiagosomda/psytonics-self-guided-study.git
tiagosomda/terminal-env	git@gitlab.com:tiagosomda/terminal-env.git
tiagosomda/tiagosomda.github.io	git@github.com:tiagosomda/tiagosomda.github.io.git
tiagosomda/tools	git@gitlab.com:tiagosomda/tools.git
REPOSITORIES

if [[ "$dry_run" == true ]]; then
  printf '\nSummary: %d would clone, %d skipped, %d blocked.\n' \
    "$cloned" "$skipped" "$blocked"
else
  printf '\nSummary: %d cloned, %d skipped, %d blocked, %d failed.\n' \
    "$cloned" "$skipped" "$blocked" "$failed"
fi

if (( blocked > 0 || failed > 0 )); then
  exit 1
fi
