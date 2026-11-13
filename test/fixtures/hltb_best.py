"""Offline checks for the HowLongToBeat matcher, run by plugin_test.dart."""

import importlib.util
import sys

# Importing the plugin for its functions must not leave a .pyc in the
# catalogue source tree; plugins/build.sh --check compares the whole folder.
sys.dont_write_bytecode = True
import sys

spec = importlib.util.spec_from_file_location('hltb', sys.argv[1])
hltb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hltb)


def result(title):
    return {
        'game_name': title,
        'game_type': 'game',
        'comp_main': 1,
        'game_id': title,
    }


CASES = {
    'Ultima Underworld 1': (
        [
            'Ultima Underworld: The Stygian Abyss',
            'Ultima Underworld II: Labyrinth of Worlds',
        ],
        'Ultima Underworld: The Stygian Abyss',
    ),
    'Ultima Underworld II': (
        [
            'Ultima Underworld: The Stygian Abyss',
            'Ultima Underworld II: Labyrinth of Worlds',
        ],
        'Ultima Underworld II: Labyrinth of Worlds',
    ),
    'Dishonored': (['Dishonored 2', 'Dishonored'], 'Dishonored'),
    'Dishonored 2': (['Dishonored', 'Dishonored 2'], 'Dishonored 2'),
    'The Witcher 3': (
        ['The Witcher 2: Assassins of Kings', 'The Witcher 3: Wild Hunt'],
        'The Witcher 3: Wild Hunt',
    ),
    'S.T.A.L.K.E.R.: Call of Prypiat - Enhanced Edition': (
        ['S.T.A.L.K.E.R.: Call of Pripyat'],
        'S.T.A.L.K.E.R.: Call of Pripyat',
    ),
    'Final Fantasy VII Remake Intergrade': (
        ['Final Fantasy VII Remake'],
        'Final Fantasy VII Remake',
    ),
    'Alan Wake 2': (['Alan Wake II'], 'Alan Wake II'),
}

for name, (titles, expected) in CASES.items():
    match = hltb.best([result(title) for title in titles], name)
    got = match.get('game_name') if match else None
    if got != expected:
        raise SystemExit('%s: %r != %r' % (name, got, expected))

if hltb.queries('HELLDIVERS\u2122 2') != ['HELLDIVERS 2']:
    raise SystemExit('the trademark survived the search query')

print('ok')
