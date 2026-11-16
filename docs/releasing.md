# Releasing Omni Launcher

`tool/release.sh` publishes a prepared release through the GitHub Actions
Flatpak workflow. It refuses to tag when the version files or the generated
manifest disagree, so the bundle cannot silently ship a different version or
commit than the tag says.

The version bump itself is committed first. The release script starts from a
clean `main` whose `HEAD` is the generated-manifest pin commit.

## 1. Bump the version

Pick the next `MAJOR.MINOR.PATCH` version and update three files:

- `pubspec.yaml`: `version: X.Y.Z+BUILD`, incrementing `BUILD` (it is part of
  the native build identity; Linux ignores it but the file should move forward).
- `lib/src/paths.dart`: `static const String version = 'X.Y.Z';`
- `flatpak/io.github.PuppyCodingBadly.OmniLauncher.metainfo.xml`: add a new
  `<release version="X.Y.Z" date="YYYY-MM-DD">` with a `<description>` above
  the previous release.

Commit those three files:

```sh
git commit -m "Version X.Y.Z: <summary>"
```

## 2. Pin the generated manifest

The workflow builds the commit named by the manifest's `commit:`, not the tag
itself. Point that line at the version commit just made:

```sh
sed -i -E "s/^(        commit: )[0-9a-f]{40}$/\1$(git rev-parse HEAD)/" \
  io.github.PuppyCodingBadly.OmniLauncher.yml
git commit -m "Flatpak: pin the generated manifest to X.Y.Z" \
  io.github.PuppyCodingBadly.OmniLauncher.yml
```

The pin must be an ancestor of the tag, and its `pubspec.yaml` and
`lib/src/paths.dart` must already carry `X.Y.Z`. The release script checks
both.

Only regenerate the manifest with `flatpak-flutter` when the Flutter version
or a pub dependency changes:

```sh
./flatpak-flutter/flatpak-flutter.py flatpak-flutter.yml
```

## 3. Publish

```sh
tool/release.sh X.Y.Z
```

The script:

1. verifies the branch, clean tree, version agreement, tag absence, and the
   manifest pin;
2. runs `flutter analyze`, `flutter test`, `plugins/build.sh --check`, and
   `appstreamcli validate --no-net`;
3. creates the annotated tag `vX.Y.Z` and pushes `main` plus the tag;
4. waits for the tag-triggered `Flatpak` workflow to succeed.

Options:

| Option | Effect |
| --- | --- |
| `--dry-run` | Run preflight and print the publish commands without changing anything. |
| `--skip-tests` | Skip the analyze/test/plugin/AppStream gates. |
| `--no-wait` | Push main and the tag, then stop. |
| `--update-local` | After the workflow succeeds, update the user Flatpak and verify it reports the new version. |

```sh
tool/release.sh X.Y.Z --update-local
```

The workflow publishes the signed OSTree repository on GitHub Pages, the
landing page, the standalone bundle, and the `.flatpakref`/`.flatpakrepo`
assets on the GitHub release. Local clients installed from the
`omnilauncher-origin` remote update from the same repository.

## Recovery

The tag is created only after every local gate passes. If the workflow fails,
the tag remains; fix the issue, tag the next patch version, and release that.
Deleting and reusing a published tag is not supported: clients may already
have fetched it.
