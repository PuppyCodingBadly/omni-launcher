#!/usr/bin/env bash
# Publish a prepared Omni Launcher release. See docs/releasing.md.
#
#   preflight -> analyze/tests/plugin catalogue/AppStream -> tag -> push main
#   and the tag -> wait for the Flatpak workflow -> optionally update the local
#   Flatpak from GitHub Pages.
#
# Version preparation and the generated-manifest pin are commits, not side
# effects of this script: the working tree must be clean, pubspec.yaml,
# lib/src/paths.dart and the metainfo must already say VERSION, and the
# manifest's pinned commit must contain those files. The pin is what the
# workflow actually builds, so the script verifies the pinned commit as well.
set -euo pipefail

APP_ID=io.github.PuppyCodingBadly.OmniLauncher
BRANCH=main
MANIFEST=io.github.PuppyCodingBadly.OmniLauncher.yml
METAINFO=flatpak/$APP_ID.metainfo.xml
PUBSPEC=pubspec.yaml
PATHS=lib/src/paths.dart

VERSION=
DRY_RUN=false
SKIP_TESTS=false
WAIT=true
UPDATE_LOCAL=false

usage() {
  cat <<'EOF'
Usage: tool/release.sh VERSION [options]

Publish Omni Launcher VERSION. The version bump and the generated manifest pin
must already be committed, and the working tree must be clean.

Options:
  --dry-run         Run preflight and print the publish commands; change nothing.
  --skip-tests      Skip flutter analyze/test, the plugin catalogue check and
                    AppStream validation.
  --no-wait         Push the tag and stop; do not wait for the Flatpak workflow.
  --update-local    After the workflow succeeds, update the local user Flatpak
                    and check that it reports VERSION. Implies a wait.
  -h, --help        Show this help.

Environment:
  FLUTTER   Flutter executable to use (default: flutter)
EOF
}

die() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

need() {
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

run() {
  if [ "$DRY_RUN" = true ]; then
    printf '  +'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --skip-tests) SKIP_TESTS=true ;;
    --no-wait) WAIT=false ;;
    --update-local)
      UPDATE_LOCAL=true
      WAIT=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [ -z "$VERSION" ] || die "unexpected argument: $1"
      VERSION=$1
      ;;
  esac
  shift
done

[ -n "$VERSION" ] || {
  usage >&2
  die "VERSION is required"
}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "VERSION must look like MAJOR.MINOR.PATCH, not '$VERSION'"

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
CALLER_DIR=$(pwd -P)
[ "$CALLER_DIR" = "$ROOT" ] ||
  die "run from the repository root: cd '$ROOT' && tool/release.sh $VERSION"
cd "$ROOT"

FLUTTER=${FLUTTER:-flutter}
TAG=v$VERSION
TAG_MESSAGE="Omni Launcher $VERSION"

need git
need sed
need awk
GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "not inside a git worktree"
[ "$GIT_TOP" = "$ROOT" ] || die "script root '$ROOT' is not the git root '$GIT_TOP'"
git remote get-url origin >/dev/null 2>&1 ||
  die "no 'origin' remote; configure one before releasing"

info "Preflight for Omni Launcher $VERSION"

[ -z "$(git status --porcelain)" ] || {
  git status --short >&2
  die "working tree is not clean; commit the release first"
}

CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD) ||
  die "detached HEAD; check out $BRANCH before releasing"
[ "$CURRENT_BRANCH" = "$BRANCH" ] ||
  die "releases are cut from $BRANCH, not '$CURRENT_BRANCH'"

git fetch --quiet origin "$BRANCH"
BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH")
[ "$BEHIND" -eq 0 ] ||
  die "local $BRANCH is $BEHIND commit(s) behind origin/$BRANCH; pull first"

if git show-ref --verify --quiet "refs/tags/$TAG"; then
  die "tag $TAG already exists locally"
fi
REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/$TAG") ||
  die "cannot read tags from origin"
[ -z "$REMOTE_TAG" ] || die "tag $TAG already exists on origin"

[ -f "$PUBSPEC" ] || die "missing $PUBSPEC"
PUBSPEC_VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC")
[ -n "$PUBSPEC_VERSION" ] || die "pubspec.yaml has no version"
case $PUBSPEC_VERSION in
  "$VERSION"|"$VERSION"+*) ;;
  *) die "pubspec.yaml version '$PUBSPEC_VERSION' does not match $VERSION" ;;
esac

grep -q "static const String version = '$VERSION';" "$PATHS" ||
  die "$PATHS does not carry version $VERSION"
grep -q -F "<release version=\"$VERSION\"" "$METAINFO" ||
  die "$METAINFO has no <release version=\"$VERSION\"> entry"

PINNED=$(sed -n -E 's/^[[:space:]]+commit:[[:space:]]*([0-9a-f]{40}).*/\1/p' \
  "$MANIFEST" | head -n 1)
[ -n "$PINNED" ] || die "$MANIFEST has no pinned commit"
git cat-file -e "$PINNED^{commit}" 2>/dev/null ||
  die "manifest pins $PINNED, which is not in this repository"
git merge-base --is-ancestor "$PINNED" HEAD ||
  die "manifest pins $PINNED, which is not an ancestor of HEAD"
PIN_VERSION=$(git show "$PINNED:$PUBSPEC" 2>/dev/null |
  sed -n 's/^version:[[:space:]]*//p')
case $PIN_VERSION in
  "$VERSION"|"$VERSION"+*) ;;
  *) die "manifest pins $PINNED, whose pubspec version '$PIN_VERSION' is not $VERSION" ;;
esac
git show "$PINNED:$PATHS" 2>/dev/null |
  grep -q "static const String version = '$VERSION';" ||
  die "manifest pins $PINNED, whose $PATHS does not carry version $VERSION"

if [ "$SKIP_TESTS" = false ]; then
  need "$FLUTTER"
  need appstreamcli
  need python3
fi

if [ "$DRY_RUN" = true ]; then
  info "Dry run: the release commit is $(git rev-parse --short HEAD)"
  info "The pinned source commit carrying $VERSION is $(git rev-parse --short "$PINNED")"
  if [ "$SKIP_TESTS" = false ]; then
    run "$FLUTTER" analyze
    run "$FLUTTER" test
    run ./plugins/build.sh --check
    run appstreamcli validate --no-net "$METAINFO"
  fi
  run git tag -a "$TAG" -m "$TAG_MESSAGE"
  run git push origin "$BRANCH"
  run git push origin "$TAG"
  if [ "$WAIT" = true ]; then
    printf '  + gh run list --workflow Flatpak --commit %q\n' "$(git rev-parse HEAD)"
    run gh run watch RUN_ID --interval 15 --exit-status
  fi
  if [ "$UPDATE_LOCAL" = true ]; then
    run flatpak update --user --noninteractive --assumeyes "$APP_ID"
    run flatpak info --user "$APP_ID"
  fi
  exit 0
fi

if [ "$SKIP_TESTS" = false ]; then
  info "Running the release gates"
  run "$FLUTTER" analyze
  run "$FLUTTER" test
  run ./plugins/build.sh --check
  run appstreamcli validate --no-net "$METAINFO"
fi

RELEASE_COMMIT=$(git rev-parse HEAD)
info "Tagging $TAG at $(git rev-parse --short HEAD)"
run git tag -a "$TAG" -m "$TAG_MESSAGE"

info "Pushing $BRANCH and $TAG"
run git push origin "$BRANCH"
run git push origin "$TAG"

if [ "$WAIT" = true ]; then
  need gh
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die "cannot resolve the GitHub repository; is gh authenticated?"
  info "Waiting for the Flatpak workflow"
  RUN_ID=
  for _ in $(seq 1 90); do
    RUN_ID=$(gh run list --repo "$REPO" --workflow Flatpak \
      --commit "$RELEASE_COMMIT" --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty')
    [ -n "$RUN_ID" ] && break
    sleep 10
  done
  [ -n "$RUN_ID" ] ||
    die "the tag was pushed, but no Flatpak workflow run appeared"
  gh run watch "$RUN_ID" --repo "$REPO" --interval 15 --exit-status ||
    die "Flatpak workflow $RUN_ID failed; inspect it with: gh run view $RUN_ID --repo $REPO"
  info "Flatpak workflow succeeded"
fi

if [ "$UPDATE_LOCAL" = true ]; then
  need flatpak
  info "Updating the local Flatpak from GitHub"
  INSTALLED=
  for _ in $(seq 1 12); do
    flatpak update --user --noninteractive --assumeyes "$APP_ID" ||
      die "flatpak update failed"
    INSTALLED=$(flatpak info --user "$APP_ID" |
      sed -n 's/^[[:space:]]*Version:[[:space:]]*//p')
    [ "$INSTALLED" = "$VERSION" ] && break
    sleep 10
  done
  [ "$INSTALLED" = "$VERSION" ] ||
    die "local Flatpak reports version '$INSTALLED', not $VERSION"
  info "Local Flatpak now reports $VERSION"
fi

info "Released $TAG"
printf 'https://github.com/%s/releases/tag/%s\n' "${REPO:-PuppyCodingBadly/omni-launcher}" "$TAG"
