#!/usr/bin/env python3
"""
marmot-curate: statistics and decisions for curating MarmotIM's user stores.

Reads the behaviour log (behavior.db, written by the input method when
词库管理 → 整理 → 记录 is on) and dictionary.db, and prints JSON. The judging is
done by whoever reads that JSON (the marmot-curate Claude skill); this tool
only counts, and records what the user decided.

    marmot_curate.py status
    marmot_curate.py candidates user-dict|suppress|order|exit
    marmot_curate.py current
    marmot_curate.py decide --file decisions.json
    marmot_curate.py history

It never modifies the three stores. `decide` writes rows to the `proposals`
table in behavior.db; the running input method applies the accepted ones
through its own APIs (index, caches, iCloud sync) and marks them applied.

Only the standard library is used.
"""

import argparse
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
import time
from collections import Counter, defaultdict
from typing import Dict, Iterable, List, Optional, Tuple

HOME = os.path.expanduser('~/Library/Application Support/MarmotIM')
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Darwin notification the input method listens for (ProposalApplier.swift)
DECIDED_NOTIFICATION = 'com.marmotim.curate.decided'

KINDS = ('add_word', 'remove_word', 'suppress', 'unsuppress', 'add_rule', 'remove_rule')

PROPOSALS_DDL = """
    CREATE TABLE IF NOT EXISTS proposals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        key TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL,
        reason TEXT,
        stats TEXT,
        decided_at REAL NOT NULL,
        applied_at REAL,
        error TEXT
    )
"""


# --------------------------------------------------------------------------
# Databases
# --------------------------------------------------------------------------

def open_behavior(path: str, write: bool = False) -> Optional[sqlite3.Connection]:
    if not os.path.exists(path):
        if not write:
            return None
        os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path, timeout=5)
    conn.row_factory = sqlite3.Row
    if write:
        conn.execute(PROPOSALS_DDL)
        conn.commit()
    return conn


def open_dictionary(path: str) -> Optional[sqlite3.Connection]:
    if not os.path.exists(path):
        return None
    conn = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def close(*connections: Optional[sqlite3.Connection]) -> None:
    for conn in connections:
        if conn is not None:
            conn.close()


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def load_events(conn: Optional[sqlite3.Connection], since: float) -> List[dict]:
    if conn is None or not table_exists(conn, 'events'):
        return []
    rows = conn.execute(
        "SELECT id, ts, kind, app, code, code_type, text, rank, trigger, page, candidates, n "
        "FROM events WHERE ts >= ? ORDER BY ts, id", (since,))
    events = []
    for row in rows:
        event = dict(row)
        event['candidates'] = json.loads(event['candidates']) if event['candidates'] else []
        events.append(event)
    return events


def load_proposals(conn: Optional[sqlite3.Connection]) -> List[dict]:
    if conn is None or not table_exists(conn, 'proposals'):
        return []
    result = []
    for row in conn.execute("SELECT * FROM proposals ORDER BY id"):
        item = dict(row)
        item['payload'] = json.loads(item['payload'])
        item['stats'] = json.loads(item['stats']) if item['stats'] else {}
        result.append(item)
    return result


def texts_in_dictionary(dict_conn: Optional[sqlite3.Connection], texts: Iterable[str]) -> set:
    """Which of `texts` exist in entries. entries has no index on text (1.5M
    rows), so look up in chunks: one table scan per chunk, not per word."""
    found = set()
    if dict_conn is None:
        return found
    texts = list(dict.fromkeys(texts))
    for i in range(0, len(texts), 500):
        chunk = texts[i:i + 500]
        marks = ','.join('?' * len(chunk))
        for (text,) in dict_conn.execute(f"SELECT DISTINCT text FROM entries WHERE text IN ({marks})", chunk):
            found.add(text)
    return found


def current_stores(dict_conn: Optional[sqlite3.Connection]) -> dict:
    stores = {'user_words': [], 'suppressed': [], 'rules': []}
    if dict_conn is None:
        return stores
    if table_exists(dict_conn, 'user_favorites'):
        stores['user_words'] = [
            {'text': r['text'], 'wubi': r['wubi_code'], 'pinyin': r['pinyin_code']}
            for r in dict_conn.execute(
                "SELECT text, wubi_code, pinyin_code FROM user_favorites WHERE is_deleted = 0 ORDER BY text")]
    if table_exists(dict_conn, 'user_suppressed_words'):
        stores['suppressed'] = [r['text'] for r in dict_conn.execute(
            "SELECT text FROM user_suppressed_words WHERE is_deleted = 0 ORDER BY text")]
    if table_exists(dict_conn, 'user_relative_order'):
        stores['rules'] = [{'a': r['word_a'], 'b': r['word_b']} for r in dict_conn.execute(
            "SELECT word_a, word_b FROM user_relative_order WHERE is_deleted = 0 ORDER BY word_a, word_b")]
    return stores


# --------------------------------------------------------------------------
# Code generation (same rules as ReverseLookupTable.swift)
# --------------------------------------------------------------------------

def wubi_code(dict_conn: Optional[sqlite3.Connection], text: str) -> Optional[str]:
    if dict_conn is None or not table_exists(dict_conn, 'char_to_wubi'):
        return None
    codes = []
    for char in text:
        row = dict_conn.execute("SELECT wubi_code FROM char_to_wubi WHERE char = ?", (char,)).fetchone()
        if row is None or not row[0]:
            return None
        codes.append(row[0])
    if len(codes) == 1:
        return codes[0][:4]
    if len(codes) == 2:
        return codes[0][:2] + codes[1][:2]
    if len(codes) == 3:
        return codes[0][:1] + codes[1][:1] + codes[2][:2]
    return codes[0][:1] + codes[1][:1] + codes[2][:1] + codes[-1][:1]


def pinyin_code(dict_conn: Optional[sqlite3.Connection], text: str) -> Optional[str]:
    """Whole-word reading if known, else each character's primary reading.
    The app resolves polyphones by context as well; a suggestion's pinyin is
    shown to the user before it is accepted, so the simpler rule is enough."""
    if dict_conn is None or not table_exists(dict_conn, 'char_to_pinyin'):
        return None
    if table_exists(dict_conn, 'polyphone_words'):
        row = dict_conn.execute("SELECT pinyin FROM polyphone_words WHERE word = ?", (text,)).fetchone()
        if row:
            return row[0]
    result = ''
    for char in text:
        row = dict_conn.execute(
            "SELECT pinyin FROM char_to_pinyin WHERE char = ? ORDER BY is_primary DESC LIMIT 1", (char,)).fetchone()
        if row is None:
            return None
        result += row[0]
    return result


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------

def is_cjk(text: str) -> bool:
    return bool(text) and all('一' <= c <= '鿿' or '㐀' <= c <= '䶿' for c in text)


def day_of(ts: float) -> int:
    return int(ts // 86400)


def entropy(counter: Counter) -> float:
    total = sum(counter.values())
    if total == 0:
        return 0.0
    return round(-sum(c / total * math.log2(c / total) for c in counter.values()), 2)


def runs_of_commits(events: List[dict], gap: float) -> List[List[dict]]:
    """Runs of consecutive Chinese selections: the user typed these one after
    another with nothing in between. A run ends at punctuation, an app switch,
    dictation, a correction, a raw/abandoned code, a different app, or a pause
    longer than `gap` seconds."""
    runs, run = [], []
    for event in events:
        continues = (
            event['kind'] == 'select'
            and is_cjk(event['text'] or '')
            and (not run or (event['ts'] - run[-1]['ts'] <= gap and event['app'] == run[-1]['app']))
        )
        if event['kind'] == 'select' and is_cjk(event['text'] or '') and not continues:
            if run:
                runs.append(run)
            run = [event]
        elif continues:
            run.append(event)
        else:
            if run:
                runs.append(run)
            run = []
    if run:
        runs.append(run)
    return runs


def rejected_counts(proposals: List[dict]) -> Dict[Tuple[str, str], int]:
    """(kind, key) -> evidence count when it was last rejected"""
    result = {}
    for item in proposals:
        if item['status'] == 'rejected':
            result[(item['kind'], item['key'])] = int(item['stats'].get('count', 0))
    return result


def still_rejected(rejected: Dict[Tuple[str, str], int], kind: str, key: str, count: int) -> bool:
    """A rejected suggestion comes back only once its evidence has doubled"""
    if (kind, key) not in rejected:
        return False
    return count < 2 * max(1, rejected[(kind, key)])


def rule_key(a: str, b: str) -> str:
    return f'{a}\u001f{b}'


# --------------------------------------------------------------------------
# Candidates: user dictionary
# --------------------------------------------------------------------------

# Looks like a credential or an identifier rather than a word. These are never
# printed, so they never reach whoever reads the output.
SECRET_PREFIXES = ('sk-', 'sk_', 'ghp_', 'gho_', 'github_pat_', 'akia', 'xox', 'eyj', 'pk_', 'rk_')


def looks_secret(text: str) -> bool:
    lower = text.lower()
    if lower.startswith(SECRET_PREFIXES):
        return True
    if '@' in text or len(text) > 24:
        return True
    digits = sum(c.isdigit() for c in text)
    if digits == len(text):
        return True
    if len(text) >= 8 and digits / len(text) >= 0.3:
        return True
    # Long, and mixes cases and digits the way generated passwords do
    if len(text) >= 12 and digits and any(c.islower() for c in text) and any(c.isupper() for c in text):
        return True
    return False


# Letters only: an accepted English word is stored with its lowercased form as
# its code, and a code can only be letters (digits pick candidates).
ENGLISH_WORD = re.compile(r'^[A-Za-z]{2,30}$')


def load_english_table() -> set:
    path = os.path.join(REPO, 'MarmotIM', 'Resources', 'en_table.txt')
    words = set()
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            for line in f:
                key = line.split('\t', 1)[0].strip()
                if key:
                    words.add(key.lower())
    return words


def user_dict_candidates(events, dict_conn, proposals, args) -> dict:
    stores = current_stores(dict_conn)
    existing = {w['text'] for w in stores['user_words']}
    rejected = rejected_counts(proposals)
    runs = runs_of_commits(events, args.gap)

    unigram = Counter()
    for run in runs:
        for event in run:
            unigram[event['text']] += 1

    grams = {}
    for run in runs:
        texts = [e['text'] for e in run]
        for n in (2, 3, 4):
            for i in range(len(run) - n + 1):
                joined = ''.join(texts[i:i + n])
                if not 2 <= len(joined) <= 8:
                    continue
                gram = grams.setdefault((joined, tuple(texts[i:i + n])), {
                    'count': 0, 'days': set(), 'apps': set(), 'left': Counter(), 'right': Counter(),
                    'keys': 0, 'contexts': []})
                gram['count'] += 1
                gram['days'].add(day_of(run[i]['ts']))
                gram['apps'].add(run[i]['app'])
                gram['left'][texts[i - 1] if i > 0 else '^'] += 1
                gram['right'][texts[i + n] if i + n < len(run) else '$'] += 1
                # Keys actually pressed: each piece's code plus its selection key
                gram['keys'] += sum(len(e['code'] or '') + 1 for e in run[i:i + n])
                if len(gram['contexts']) < 3:
                    gram['contexts'].append(
                        ''.join(texts[max(0, i - 3):i]) + '【' + joined + '】' + ''.join(texts[i + n:i + n + 3]))

    strong = {key: g for key, g in grams.items()
              if g['count'] >= args.min_count and len(g['days']) >= args.min_days}
    in_dictionary = texts_in_dictionary(dict_conn, [joined for joined, _ in strong])

    phrases = []
    for (joined, parts), gram in strong.items():
        if joined in existing or joined in in_dictionary:
            continue  # Already typeable as one word
        if still_rejected(rejected, 'add_word', joined, gram['count']):
            continue
        wubi = wubi_code(dict_conn, joined)
        item = {
            'text': joined,
            'typed_as': list(parts),
            'count': gram['count'],
            'days': len(gram['days']),
            'apps': len(gram['apps']),
            # Share of the rarer piece's uses that were inside this phrase
            'cohesion': round(gram['count'] / max(1, min(unigram[p] for p in parts)), 2),
            # Variety of what comes before / after: high for a free-standing
            # word, low for a fragment of one fixed sentence
            'left_entropy': entropy(gram['left']),
            'right_entropy': entropy(gram['right']),
            'keys_saved_per_use': round(gram['keys'] / gram['count'] - (len(wubi) + 1), 1) if wubi else None,
            'wubi': wubi,
            'pinyin': pinyin_code(dict_conn, joined),
        }
        if not args.no_context:
            item['contexts'] = gram['contexts']
        phrases.append(item)
    phrases.sort(key=lambda c: (-c['count'], c['text']))

    english_table = load_english_table()
    raw_days: Dict[str, set] = defaultdict(set)
    raw_forms: Dict[str, Counter] = defaultdict(Counter)
    for event in events:
        text = event['text'] or ''
        if event['kind'] != 'raw' or not ENGLISH_WORD.match(text) or looks_secret(text):
            continue
        raw_days[text.lower()].add(day_of(event['ts']))
        raw_forms[text.lower()][text] += 1

    english = []
    for lower, forms in raw_forms.items():
        count = sum(forms.values())
        if count < args.min_count_english or len(raw_days[lower]) < args.min_days:
            continue
        form = forms.most_common(1)[0][0]
        if lower in english_table or form in existing:
            continue  # Already offered as an English candidate
        if still_rejected(rejected, 'add_word', form, count):
            continue
        english.append({
            'text': form,
            'count': count,
            'days': len(raw_days[lower]),
            'forms': dict(forms),
            'english': True,
        })
    english.sort(key=lambda c: (-c['count'], c['text']))

    return {'phrases': phrases[:args.limit], 'english': english[:args.limit]}


# --------------------------------------------------------------------------
# Candidates: suppression
# --------------------------------------------------------------------------

def suppress_candidates(events, dict_conn, proposals, args) -> dict:
    suppressed = set(current_stores(dict_conn)['suppressed'])
    rejected = rejected_counts(proposals)

    stats = defaultdict(lambda: {'top': 0, 'boosted_top': 0, 'skipped': 0, 'boosted_skipped': 0,
                                 'days': set(), 'codes': Counter(), 'instead': Counter(), 'contexts': []})
    picks = Counter()
    previous = None
    for event in events:
        if event['kind'] != 'select':
            previous = None if event['kind'] == 'break' else previous
            continue
        picks[event['text']] += 1
        shown = event['candidates']
        if shown:
            top = shown[0]
            entry = stats[top['t']]
            entry['top'] += 1
            entry['codes'][event['code']] += 1
            boosted = bool(top.get('b'))
            if boosted:
                entry['boosted_top'] += 1
                entry['days'].add(day_of(event['ts']))
            if event['text'] != top['t']:
                entry['skipped'] += 1
                entry['instead'][event['text']] += 1
                if boosted:
                    entry['boosted_skipped'] += 1
                if len(entry['contexts']) < 3 and previous:
                    entry['contexts'].append(f"{previous}【选了 {event['text']}，跳过 {top['t']}】")
        previous = event['text']

    result = []
    for text, entry in stats.items():
        if text in suppressed:
            continue
        if entry['boosted_top'] < args.min_count or len(entry['days']) < args.min_days:
            continue
        if still_rejected(rejected, 'suppress', text, entry['boosted_top']):
            continue
        item = {
            'text': text,
            # Evidence count used for the "rejected until doubled" rule
            'count': entry['boosted_top'],
            'shown_first': entry['top'],
            'shown_first_by_learning': entry['boosted_top'],
            'skipped_when_first': entry['skipped'],
            'skipped_when_first_by_learning': entry['boosted_skipped'],
            'skip_rate_by_learning': round(entry['boosted_skipped'] / entry['boosted_top'], 2),
            'times_picked': picks[text],
            'days': len(entry['days']),
            'codes': dict(entry['codes'].most_common(5)),
            'picked_instead': dict(entry['instead'].most_common(5)),
        }
        if not args.no_context:
            item['contexts'] = entry['contexts']
        result.append(item)
    result.sort(key=lambda c: (-c['skipped_when_first_by_learning'], c['text']))
    return {'suppress': result[:args.limit]}


# --------------------------------------------------------------------------
# Candidates: relative ordering
# --------------------------------------------------------------------------

def would_create_cycle(rules: List[dict], a: str, b: str) -> bool:
    """Adding a→b closes a cycle if a is already reachable from b
    (RelativeOrderingStore.wouldCreateCycle)."""
    graph = defaultdict(list)
    for rule in rules:
        graph[rule['a']].append(rule['b'])
    stack, seen = [b], set()
    while stack:
        node = stack.pop()
        if node == a:
            return True
        if node in seen:
            continue
        seen.add(node)
        stack.extend(graph[node])
    return False


def order_candidates(events, dict_conn, proposals, args) -> dict:
    rules = current_stores(dict_conn)['rules']
    existing = {(r['a'], r['b']) for r in rules}
    rejected = rejected_counts(proposals)

    # pair is stored with its two words sorted, so (A,B) and (B,A) share a row
    pairs = defaultdict(lambda: {'picked': Counter(), 'overrode': Counter(), 'co_shown': 0, 'days': set(),
                                 'codes': set(), 'jianma': False, 'order': [], 'contexts': defaultdict(list)})
    previous = None
    for event in events:
        if event['kind'] != 'select':
            previous = None if event['kind'] == 'break' else previous
            continue
        shown = event['candidates']
        chosen = event['text']
        position = {c['t']: i for i, c in enumerate(shown)}
        if chosen in position:
            for other in shown:
                if other['t'] == chosen:
                    continue
                key = tuple(sorted((chosen, other['t'])))
                pair = pairs[key]
                pair['co_shown'] += 1
                pair['picked'][chosen] += 1
                pair['days'].add(day_of(event['ts']))
                pair['codes'].add(event['code'])
                chosen_j = shown[position[chosen]].get('j')
                pair['jianma'] = pair['jianma'] or bool(other.get('j')) or bool(chosen_j)
                # Which of the pair was ranked higher this time
                pair['order'].append(chosen if position[chosen] < position[other['t']] else other['t'])
                if position[other['t']] < position[chosen]:
                    pair['overrode'][chosen] += 1  # The other was above, the user reached past it
                if previous and len(pair['contexts'][chosen]) < 3:
                    pair['contexts'][chosen].append(f'{previous}【{chosen}】')
        previous = chosen

    result = []
    for (x, y), pair in pairs.items():
        if pair['co_shown'] < args.min_count_order or len(pair['days']) < args.min_days:
            continue
        a, b = (x, y) if pair['picked'][x] >= pair['picked'][y] else (y, x)
        if pair['overrode'][a] < 2:
            continue  # a is already above b when it is wanted; nothing to fix
        if pair['jianma'] or (a, b) in existing:
            continue  # Rules never move a protected short code; rule exists
        if would_create_cycle(rules, a, b):
            continue
        if still_rejected(rejected, 'add_rule', rule_key(a, b), pair['co_shown']):
            continue
        flips = sum(1 for i in range(1, len(pair['order'])) if pair['order'][i] != pair['order'][i - 1])
        item = {
            'a': a,
            'b': b,
            'count': pair['co_shown'],
            'shown_together': pair['co_shown'],
            'picked_a': pair['picked'][a],
            'picked_b': pair['picked'][b],
            'a_share': round(pair['picked'][a] / pair['co_shown'], 2),
            # Times a was picked although b was ranked above it
            'picked_a_past_b': pair['overrode'][a],
            'picked_b_past_a': pair['overrode'][b],
            # Times the two swapped places from one occurrence to the next
            'order_flips': flips,
            'days': len(pair['days']),
            'codes': sorted(pair['codes'])[:5],
            'reverse_rule_exists': (b, a) in existing,
        }
        if not args.no_context:
            item['contexts'] = {'picked_a': pair['contexts'][a], 'picked_b': pair['contexts'][b]}
        result.append(item)
    result.sort(key=lambda c: (-c['picked_a_past_b'], -c['a_share'], c['a']))
    return {'order': result[:args.limit]}


# --------------------------------------------------------------------------
# Candidates: exit (what was accepted through this tool and may no longer fit)
# --------------------------------------------------------------------------

def learning_count(dict_conn: Optional[sqlite3.Connection], text: str) -> Optional[int]:
    """Selections of `text` across every Mac: the synced per-device counts if
    present, else this Mac's user_learning."""
    if dict_conn is None:
        return None
    if table_exists(dict_conn, 'sync_counter_state'):
        row = dict_conn.execute(
            "SELECT SUM(count) FROM sync_counter_state "
            "WHERE payload = 'learning' AND key = ? AND device_id != '__baseline__'", (text,)).fetchone()
        if row and row[0] is not None:
            return int(row[0])
    row = dict_conn.execute(
        "SELECT MAX(ul.access_count) FROM user_learning ul JOIN entries e ON e.id = ul.entry_id WHERE e.text = ?",
        (text,)).fetchone()
    return int(row[0]) if row and row[0] is not None else 0


def exit_candidates(events, dict_conn, proposals, args) -> dict:
    stores = current_stores(dict_conn)
    now = time.time()
    result = []
    for item in proposals:
        if item['status'] != 'applied' or item['kind'] not in ('add_word', 'suppress', 'add_rule'):
            continue
        applied_at = item['applied_at'] or item['decided_at']
        since = [e for e in events if e['ts'] >= applied_at and e['kind'] == 'select']
        days_in_effect = round((now - applied_at) / 86400, 1)
        payload = item['payload']

        if item['kind'] == 'add_word':
            text = payload['text']
            if text not in {w['text'] for w in stores['user_words']}:
                continue  # Removed by hand since; nothing left to exit
            shown = sum(1 for e in since if any(c['t'] == text for c in e['candidates']))
            picked = sum(1 for e in since if e['text'] == text)
            at_apply = item['stats'].get('learning_at_decision')
            total = learning_count(dict_conn, text)
            result.append({
                'kind': 'remove_word', 'text': text, 'days_in_effect': days_in_effect,
                # All Macs, from the synced learning counts
                'picked_since_all_macs': None if total is None or at_apply is None else max(0, total - at_apply),
                'picked_since_this_mac': picked,
                'shown_but_skipped_this_mac': shown - picked,
            })
        elif item['kind'] == 'suppress':
            text = payload['text']
            if text not in stores['suppressed']:
                continue
            picked = [e for e in since if e['text'] == text]
            codes = {e['code'] for e in picked}
            at_codes = sum(1 for e in since if e['code'] in codes)
            result.append({
                'kind': 'unsuppress', 'text': text, 'days_in_effect': days_in_effect,
                'picked_since': len(picked),
                'selections_at_its_codes': at_codes,
                'share_at_its_codes': round(len(picked) / at_codes, 2) if at_codes else None,
            })
        else:
            a, b = payload['a'], payload['b']
            if {'a': a, 'b': b} not in stores['rules']:
                continue
            together = [e for e in since if {a, b} <= {c['t'] for c in e['candidates']}]
            picked_b = sum(1 for e in together if e['text'] == b)
            picked_a = sum(1 for e in together if e['text'] == a)
            result.append({
                'kind': 'remove_rule', 'a': a, 'b': b, 'days_in_effect': days_in_effect,
                'shown_together_since': len(together),
                'picked_a_since': picked_a,
                'picked_b_since': picked_b,
                'b_share_since': round(picked_b / len(together), 2) if together else None,
            })
    return {'exit': result[:args.limit]}


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_status(args) -> dict:
    behavior = open_behavior(args.behavior_db)
    proposals = load_proposals(behavior)
    if behavior is None or not table_exists(behavior, 'events'):
        close(behavior)
        return {'recording': False, 'events': 0, 'days': 0,
                'note': '没有行为记录。请在 MarmotIM 设置 → 词库管理 → 整理 里打开记录。'}
    row = behavior.execute(
        "SELECT COUNT(*), COUNT(DISTINCT CAST(ts / 86400 AS INTEGER)), MIN(ts), MAX(ts) FROM events").fetchone()
    kinds = dict(behavior.execute("SELECT kind, COUNT(*) FROM events GROUP BY kind").fetchall())
    behavior.close()
    decided = [p['decided_at'] for p in proposals]
    return {
        'events': row[0],
        'days': row[1],
        'first_event': row[2],
        'last_event': row[3],
        'hours_since_last_event': round((time.time() - row[3]) / 3600, 1) if row[3] else None,
        'by_kind': kinds,
        'last_curated': max(decided) if decided else None,
        'decisions': dict(Counter(p['status'] for p in proposals)),
    }


def cmd_candidates(args) -> dict:
    behavior = open_behavior(args.behavior_db)
    dictionary = open_dictionary(args.dictionary_db)
    events = load_events(behavior, time.time() - args.days * 86400)
    proposals = load_proposals(behavior)
    compute = {'user-dict': user_dict_candidates, 'suppress': suppress_candidates,
               'order': order_candidates, 'exit': exit_candidates}[args.what]
    result = compute(events, dictionary, proposals, args)
    close(behavior, dictionary)
    result['window_days'] = args.days
    result['events_in_window'] = len(events)
    return result


def cmd_current(args) -> dict:
    dictionary = open_dictionary(args.dictionary_db)
    stores = current_stores(dictionary)
    close(dictionary)
    return stores


def proposal_key(kind: str, payload: dict) -> str:
    if kind in ('add_rule', 'remove_rule'):
        return rule_key(payload['a'], payload['b'])
    return payload['text']


def validate_decision(item: dict) -> Optional[str]:
    if item.get('kind') not in KINDS:
        return f"kind must be one of {', '.join(KINDS)}"
    if item.get('decision') not in ('accept', 'reject'):
        return "decision must be 'accept' or 'reject'"
    kind = item['kind']
    if kind in ('add_rule', 'remove_rule'):
        if not item.get('a') or not item.get('b') or item['a'] == item['b']:
            return 'a rule needs two different words: a and b'
    elif not item.get('text'):
        return 'text is required'
    if kind == 'add_word' and item['decision'] == 'accept':
        wubi, pinyin = item.get('wubi'), item.get('pinyin')
        if item.get('english'):
            if not ENGLISH_WORD.match(item['text']):
                return 'an English word must be letters only, so that it can be typed as its own code'
        else:
            if not wubi and not pinyin:
                return 'add_word needs a wubi or pinyin code'
            if wubi and not re.fullmatch(r'[a-z]{1,4}', wubi):
                return 'wubi code must be 1-4 lowercase letters'
            if pinyin and not re.fullmatch(r'[a-z]+', pinyin):
                return 'pinyin code must be lowercase letters'
    return None


def cmd_decide(args) -> dict:
    with open(args.file, encoding='utf-8') as f:
        decisions = json.load(f)
    if not isinstance(decisions, list):
        return {'error': 'the file must contain a JSON list of decisions'}

    errors = [{'index': i, 'error': e} for i, e in ((i, validate_decision(d)) for i, d in enumerate(decisions)) if e]
    if errors:
        return {'error': 'nothing was written', 'invalid': errors}

    behavior = open_behavior(args.behavior_db, write=True)
    dictionary = open_dictionary(args.dictionary_db)
    now = time.time()
    ids = []
    for item in decisions:
        kind = item['kind']
        payload = {k: item[k] for k in ('text', 'wubi', 'pinyin', 'english', 'a', 'b') if item.get(k) is not None}
        stats = dict(item.get('stats') or {})
        if kind == 'add_word':
            stats['learning_at_decision'] = learning_count(dictionary, payload['text']) or 0
        cursor = behavior.execute(
            "INSERT INTO proposals (kind, key, payload, status, reason, stats, decided_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (kind, proposal_key(kind, payload), json.dumps(payload, ensure_ascii=False),
             'accepted' if item['decision'] == 'accept' else 'rejected',
             item.get('reason'), json.dumps(stats, ensure_ascii=False), now))
        ids.append(cursor.lastrowid)
    behavior.commit()

    accepted = [i for i, d in zip(ids, decisions) if d['decision'] == 'accept']
    if accepted and not args.no_notify:
        # Wake the input method; it applies accepted rows and marks them
        subprocess.run(['/usr/bin/notifyutil', '-p', DECIDED_NOTIFICATION], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + args.wait
        while time.time() < deadline:
            pending = behavior.execute(
                f"SELECT COUNT(*) FROM proposals WHERE status = 'accepted' AND id IN ({','.join('?' * len(accepted))})",
                accepted).fetchone()[0]
            if pending == 0:
                break
            time.sleep(0.3)

    rows = behavior.execute(
        f"SELECT id, kind, key, status, error FROM proposals WHERE id IN ({','.join('?' * len(ids))}) ORDER BY id",
        ids).fetchall()
    results = [dict(r) for r in rows]
    close(behavior, dictionary)
    waiting = [r for r in results if r['status'] == 'accepted']
    return {
        'written': len(results),
        'results': results,
        'note': ('有 %d 条已接受但尚未生效：输入法没有在运行，或还没处理到。它们会在输入法下次启动时生效。' % len(waiting))
        if waiting else None,
    }


def cmd_history(args) -> dict:
    behavior = open_behavior(args.behavior_db)
    proposals = load_proposals(behavior)
    close(behavior)
    if args.status:
        proposals = [p for p in proposals if p['status'] == args.status]
    return {'proposals': proposals[-args.limit:]}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description='Statistics and decisions for curating MarmotIM user stores.')
    parser.add_argument('--behavior-db', default=os.path.join(HOME, 'behavior.db'))
    parser.add_argument('--dictionary-db', default=os.path.join(HOME, 'dictionary.db'))
    sub = parser.add_subparsers(dest='command', required=True)

    sub.add_parser('status', help='How much has been recorded')

    candidates = sub.add_parser('candidates', help='Candidates with their statistics')
    candidates.add_argument('what', choices=['user-dict', 'suppress', 'order', 'exit'])
    candidates.add_argument('--days', type=int, default=30, help='Window of events to use (default 30)')
    candidates.add_argument('--limit', type=int, default=50, help='At most this many per list (default 50)')
    candidates.add_argument('--no-context', action='store_true', help='Leave out the surrounding-text samples')
    candidates.add_argument('--gap', type=float, default=5.0,
                            help='Seconds between two selections for them to count as consecutive (default 5)')
    candidates.add_argument('--min-count', type=int, default=5, help='Minimum evidence (default 5)')
    candidates.add_argument('--min-count-english', type=int, default=3)
    candidates.add_argument('--min-count-order', type=int, default=6)
    candidates.add_argument('--min-days', type=int, default=2, help='Seen on at least this many days (default 2)')

    sub.add_parser('current', help='What the three stores hold now')

    decide = sub.add_parser('decide', help="Record the user's decisions; accepted ones are applied by the input method")
    decide.add_argument('--file', required=True, help='JSON list of decisions')
    decide.add_argument('--wait', type=float, default=6.0, help='Seconds to wait for the input method to apply')
    decide.add_argument('--no-notify', action='store_true', help='Do not wake the input method (tests)')

    history = sub.add_parser('history', help='Past decisions and their state')
    history.add_argument('--status', choices=['accepted', 'rejected', 'applied', 'failed'])
    history.add_argument('--limit', type=int, default=200)
    return parser


COMMANDS = {'status': cmd_status, 'candidates': cmd_candidates, 'current': cmd_current,
            'decide': cmd_decide, 'history': cmd_history}


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    result = COMMANDS[args.command](args)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write('\n')
    return 1 if isinstance(result, dict) and result.get('error') else 0


if __name__ == '__main__':
    sys.exit(main())
