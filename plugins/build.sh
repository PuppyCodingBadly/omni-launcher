#!/bin/sh
# Build the plugin catalogue from the plugin sources in this folder:
#
#   plugins/<id>/       the plugin's own files, which is what you edit
#   plugins/<id>.zip    what the launcher downloads
#   plugins/index.json  what the store lists
#
# Run it after changing a plugin, and commit what it writes. `--check` builds
# the catalogue in memory and compares it with what is committed, which is what
# CI runs.
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

python3 - "$SELF" "${1:-}" <<'PY'
"""Build, or check, the plugin catalogue.

The zips are written by hand rather than by `zip`, because a reproducible
comparison is the point of the check: same names, same contents, whatever the
timestamps are.
"""

import hashlib
import io
import json
import os
import sys
import zipfile

root, mode = sys.argv[1], sys.argv[2]


def folders():
    for entry in sorted(os.listdir(root)):
        folder = os.path.join(root, entry)
        if os.path.isdir(folder) and os.path.exists(os.path.join(folder, 'plugin.json')):
            yield entry, folder


def files(folder):
    """Every file in a plugin, by the name it has inside the archive."""
    for current, _, names in os.walk(folder):
        for name in sorted(names):
            path = os.path.join(current, name)
            yield os.path.relpath(path, folder), path


def archive(entry, folder):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as writer:
        for name, path in files(folder):
            writer.write(path, name)
    return buffer.getvalue()


def index(entries):
    return json.dumps({'plugins': entries}, indent=2) + '\n'


def read_zip(path):
    """A committed archive as {name: contents}, for comparing."""
    with zipfile.ZipFile(path) as reader:
        return {name: reader.read(name) for name in reader.namelist()}


problems = []
built = []
for entry, folder in folders():
    manifest = json.load(open(os.path.join(folder, 'plugin.json')))
    # A manifest that names another folder would ship a plugin under an id it
    # does not have on disk, and the launcher refuses that mismatch anyway.
    if manifest.get('id') != entry:
        problems.append('%s/plugin.json: id is not the folder name' % entry)
        continue
    wanted = archive(entry, folder)
    built.append(
        {
            'id': manifest['id'],
            'name': manifest['name'],
            'description': manifest.get('description', ''),
            'author': manifest.get('author', ''),
            'version': manifest.get('version', 1),
            'file': entry + '.zip',
            # The launcher checks the downloaded archive against this before
            # it unpacks anything.
            'sha256': hashlib.sha256(wanted).hexdigest(),
        }
    )
    target = os.path.join(root, entry + '.zip')
    if mode == '--check':
        if not os.path.exists(target):
            problems.append('%s.zip is missing' % entry)
            continue
        committed = read_zip(target)
        source = {name: open(path, 'rb').read() for name, path in files(folder)}
        if committed != source:
            problems.append('%s.zip does not match %s/' % (entry, entry))
        # The index's checksum is over the archive's bytes, so the committed
        # file itself has to be what was built, not merely hold the same
        # contents.
        if hashlib.sha256(open(target, 'rb').read()).hexdigest() != built[-1]['sha256']:
            problems.append('%s.zip is not the archive index.json checksums' % entry)
    else:
        with open(target, 'wb') as handle:
            handle.write(wanted)

wanted_index = index(built)
target = os.path.join(root, 'index.json')
if mode == '--check':
    if not os.path.exists(target) or open(target).read() != wanted_index:
        problems.append('index.json is out of date')
else:
    with open(target, 'w') as handle:
        handle.write(wanted_index)

if problems:
    for problem in problems:
        print('plugins: %s' % problem, file=sys.stderr)
    print('run plugins/build.sh and commit what it writes', file=sys.stderr)
    sys.exit(1)
print('%s: %d plugins' % ('checked' if mode == '--check' else 'wrote', len(built)))
PY
