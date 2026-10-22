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
import sys
import time
import urllib.error
import urllib.request

SITE = 'https://howlongtobeat.com'
UA = (
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/124.0 Safari/537.36'
)
# The runner kills a plugin after 30s, and a lookup makes two requests; each
# gets half that with room to spare.
TIMEOUT = 10

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


def search(name):
    body = {
        'searchType': 'games',
        'searchTerms': name.split(),
        'searchPage': 1,
        'size': 20,
        'searchOptions': SEARCH_OPTIONS,
        'useCache': True,
    }
    payload = fetch(
        SITE + '/api/search/site',
        data=json.dumps(body).encode('utf-8'),
        method='POST',
        headers={'Content-Type': 'application/json', 'x-auth-token': token()},
    )
    return json.loads(payload).get('data') or []


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


def normalise(text):
    return ''.join(character for character in text.lower() if character.isalnum())


def best(results, name):
    """The result that is this game, rather than one that merely mentions it."""
    wanted = normalise(name)
    scored = []
    for result in results:
        title = normalise(str(result.get('game_name', '')))
        score = 0
        if title == wanted:
            score = 3
        elif title.startswith(wanted) or wanted.startswith(title):
            score = 2
        elif wanted in title:
            score = 1
        if str(result.get('game_type', 'game')) != 'game':
            score -= 1  # an add-on is not the game itself
        if not result.get('comp_main'):
            score -= 1  # nobody has timed it, so there is nothing to show
        scored.append((score, result))
    if not scored:
        return None
    score, result = max(scored, key=lambda pair: pair[0])
    return result if score > 0 else None


def answer(name):
    game = best(search(name), name)
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
