#!/usr/bin/env python3
"""HowLongToBeat for Omni Launcher.

Reads the launcher's request as JSON on stdin and writes the answer as JSON on
stdout. Only the standard library is used, so there is nothing to install
beyond python3 itself.

HowLongToBeat has no public API. This calls the search the site's own front end
calls: /api/search/site/init hands out a token, and /api/search/site takes the
search with that token in the x-auth-token header. The token is tied to the
client that asked for it, so it is fetched fresh for every lookup.
"""

import json
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from difflib import SequenceMatcher

SITE = 'https://howlongtobeat.com'
UA = (
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/124.0 Safari/537.36'
)
# The runner kills a plugin after 30s. A lookup makes one token request and
# up to two searches; 8s each leaves room for the process and the fallback.
TIMEOUT = 8

# The most a single answer may weigh: the site's answers are kilobytes, so a
# megabyte is already generous, and beyond it something is wrong.
MAX_BODY = 1024 * 1024

# The search takes the site's whole filter object; most of it stays empty.
SEARCH_OPTIONS = {
    'games': {
        'userId': 0,
        'platform': {'mode': 'include', 'values': []},
        'sortCategory': 'popular',
        'rangeCategory': 'main',
        'rangeTime': {'min': None, 'max': None},
        'gameplay': {
            'perspective': {'mode': 'include', 'values': []},
            'flow': {'mode': 'include', 'values': []},
            'genre': {'mode': 'include', 'values': []},
        },
        'year': {'mode': 'include', 'values': []},
        'modifier': '',
    },
    'users': {'sortCategory': 'postcount'},
    'lists': {'sortCategory': 'follows'},
    'filter': '',
    'sort': 0,
    'randomizer': 0,
}

# What the answer says, and which field of a result it comes from.
TIMES = (
    ('Main story', 'comp_main'),
    ('Main + extra', 'comp_plus'),
    ('Completionist', 'comp_100'),
)

# Editions and pack-in names that the site's own title usually leaves out.
# One suffix is removed per comparison, longest first; removing everything
# would turn "Final Fantasy VII Remake" into "Final Fantasy VII".
EDITION_SUFFIXES = (
    'game of the year edition',
    'goty edition',
    'definitive edition',
    'deluxe edition',
    'ultimate edition',
    'enhanced edition',
    'complete edition',
    'special edition',
    'anniversary edition',
    'windows edition',
    'remastered collection',
    'remastered',
    'remake',
    'intergrade',
    "director's cut",
    "developer's cut",
    'deluxe',
)

# Small roman numerals the site still uses in series titles. Single-letter
# numerals stay out on purpose: "Mega Man X" is not "Mega Man 10".
ROMAN = {
    'ii': '2',
    'iii': '3',
    'iv': '4',
    'vi': '6',
    'vii': '7',
    'viii': '8',
    'ix': '9',
    'xi': '11',
    'xii': '12',
    'xiii': '13',
    'xiv': '14',
    'xv': '15',
    'xvi': '16',
    'xvii': '17',
    'xviii': '18',
    'xix': '19',
    'xx': '20',
}


def emit(payload):
    print(json.dumps(payload))
    sys.stdout.flush()


def fetch(url, data=None, headers=None, method=None):
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            'User-Agent': UA,
            'Referer': SITE + '/',
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            **(headers or {}),
        },
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        body = response.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            raise ValueError('the answer is larger than {} bytes'.format(MAX_BODY))
        return body.decode('utf-8', 'replace')


def token():
    url = '{}/api/search/site/init?t={}'.format(SITE, int(time.time() * 1000))
    return json.loads(fetch(url, headers={'Accept': 'application/json'}))['token']


def search(name, auth):
    body = {
        'searchType': 'games',
        'searchTerms': query_terms(name),
        'searchPage': 1,
        'size': 20,
        'searchOptions': SEARCH_OPTIONS,
        'useCache': True,
    }
    payload = fetch(
        SITE + '/api/search/site',
        data=json.dumps(body).encode('utf-8'),
        method='POST',
        headers={'Content-Type': 'application/json', 'x-auth-token': auth},
    )
    return json.loads(payload).get('data') or []


def query_terms(name):
    """The words to send to the site, without decoration the index drops."""
    terms = []
    for token in plain(name).split():
        token = token.strip("':;,.!?\"()[]{}-\u2013\u2014")
        if token:
            terms.append(token)
    return terms


def queries(name):
    """The game's name, then the same name without an edition suffix."""
    full = ' '.join(plain(name).split())
    stripped = editionless(name)
    if not full:
        return []
    if normalise(stripped) == normalise(full):
        return [full]
    return [full, stripped]


def search_results(name):
    """Results for the full name, falling back to its editionless form.

    The site's search is literal enough that "Definitive Edition" can return
    nothing even when the game is there under its plain title. The token is
    fetched once and reused: two queries are two posts, not two handshakes.
    """
    auth = token()
    results = []
    for query in queries(name):
        results.extend(search(query, auth))
        results = unique(results)
        if best(results, name) is not None:
            break
    return results


def duration(seconds):
    """Seconds in the launcher's own wording: 54h 32m, 27h, 45m."""
    minutes = int(seconds or 0) // 60
    if minutes <= 0:
        return ''
    hours, rest = divmod(minutes, 60)
    if hours == 0:
        return '{}m'.format(rest)
    if rest == 0:
        return '{}h'.format(hours)
    return '{}h {}m'.format(hours, rest)


def plain(text):
    """Text without trademark marks, accents or other decoration."""
    # The marks go before NFKD: normalising would turn (TM) into the letters
    # "TM" and leave them in the search.
    text = str(text).replace('\u2122', ' ').replace('\u00ae', ' ').replace('\u00a9', ' ')
    text = unicodedata.normalize('NFKD', text)
    return ''.join(character for character in text if not unicodedata.combining(character))


def editionless(text):
    """The name without one trailing edition or pack-in phrase."""
    text = re.sub(r'[\(\[].*?[\)\]]', ' ', plain(text).casefold())
    stripped = ' '.join(text.split()).rstrip(' :-\u2013\u2014')
    for suffix in EDITION_SUFFIXES:
        if stripped.endswith(suffix):
            stripped = stripped[: -len(suffix)]
            break
    return ' '.join(stripped.strip(' :-\u2013\u2014').split())


def game_base(text):
    """The name used for matching, with a trailing first-game 1 dropped.

    Stores often put "1" on the first game while the site leaves it off, so
    "Ultima Underworld 1" has to meet "Ultima Underworld".
    """
    return re.sub(r'\s+1$', '', editionless(text))


def normalise(text):
    text = plain(text).lower().replace('&', ' and ')
    tokens = re.findall(r'[a-z0-9]+', text)
    return ''.join(ROMAN.get(token, token) for token in tokens)


def numbers(text):
    """Sequel numbers, with years and first-game numbers left out."""
    return {
        int(value)
        for value in re.findall(r'\d+', text)
        if 1 < int(value) <= 99
    }


def conflicting_numbers(wanted, title):
    """Whether two titles disagree about which game in a series they are.

    A missing number on either side is a conflict too: "Dishonored" must not
    match "Dishonored 2", and the reverse is just as wrong.
    """
    wanted_numbers = numbers(wanted)
    title_numbers = numbers(title)
    if not wanted_numbers and not title_numbers:
        return False
    return wanted_numbers != title_numbers


def unique(results):
    seen = set()
    kept = []
    for result in results:
        key = (result.get('game_id'), normalise(result.get('game_name', '')))
        if key in seen:
            continue
        seen.add(key)
        kept.append(result)
    return kept


def score(result, name):
    """How strongly a result is this game rather than a neighbour.

    Exact names win, then containment. Only when neither holds does the
    similarity of the two editionless names decide, and even then a sequel
    number has to agree: a typo should find the game, not its sequel.
    """
    wanted = normalise(name)
    wanted_base = normalise(game_base(name))
    title = normalise(result.get('game_name', ''))
    title_base = normalise(game_base(result.get('game_name', '')))
    if title == wanted or title_base == wanted_base:
        value = 4
    elif not conflicting_numbers(wanted_base, title_base) and (
        title.startswith(wanted)
        or wanted.startswith(title)
        or wanted in title
        or title in wanted
        or title_base.startswith(wanted_base)
        or wanted_base.startswith(title_base)
        or wanted_base in title_base
        or title_base in wanted_base
    ):
        value = 3
    else:
        ratio = SequenceMatcher(None, wanted_base, title_base).ratio()
        if ratio < 0.86 or conflicting_numbers(wanted_base, title_base):
            return 0
        value = 2
    if str(result.get('game_type', 'game')) != 'game':
        value -= 1  # an add-on is not the game itself
    if not result.get('comp_main'):
        value -= 1  # nobody has timed it, so there is nothing to show
    return value


def best(results, name):
    """The result that is this game, rather than one that merely mentions it."""
    if not results:
        return None
    value, result = max(
        ((score(entry, name), entry) for entry in results),
        key=lambda pair: pair[0],
    )
    return result if value >= 2 else None


def answer(name):
    game = best(search_results(name), name)
    if game is None:
        return {'error': 'No match for "{}" on HowLongToBeat.'.format(name)}
    fields = []
    for label, key in TIMES:
        value = duration(game.get(key))
        if value:
            fields.append({'label': label, 'value': value})
    matched = str(game.get('game_name', ''))
    if normalise(matched) != normalise(name):
        fields.append({'label': 'Matched', 'value': matched})
    return {
        'fields': fields,
        'url': '{}/game/{}'.format(SITE, game.get('game_id')),
    }


def main():
    try:
        request = json.load(sys.stdin)
    except ValueError:
        emit({'error': 'The request was not JSON.'})
        return 0
    if not isinstance(request, dict):
        emit({'error': 'The request was not a JSON object.'})
        return 0

    game = request.get('game')
    if not isinstance(game, dict):
        game = {}
    name = str(game.get('name') or '').strip()
    if not name:
        emit({'error': 'The request named no game.'})
        return 0

    try:
        emit(answer(name))
    except urllib.error.HTTPError as error:
        if error.code == 429:
            emit({'error': 'HowLongToBeat is rate limiting: try again in a minute.'})
        else:
            emit(
                {
                    'error': 'HowLongToBeat answered {} {}.'.format(
                        error.code, error.reason
                    )
                }
            )
    except OSError as error:
        emit({'error': 'Could not reach HowLongToBeat: {}'.format(error)})
    except ValueError:
        emit({'error': 'HowLongToBeat answered something unusable.'})
    except (KeyError, TypeError, AttributeError):
        # The site's payload changed shape under the plugin: say so as an
        # answer, rather than as a traceback the launcher cannot show.
        emit({'error': 'HowLongToBeat changed the shape of its answers.'})
    return 0


if __name__ == '__main__':
    sys.exit(main())
