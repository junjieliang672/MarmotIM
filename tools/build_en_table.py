#!/usr/bin/env python3
"""
Build vocab/en_table.txt, the English word list, and copy it to
MarmotIM/Resources/en_table.txt (the copy the app loads from its bundle).

Usage:
    python3 tools/build_en_table.py                # needs `pip install wordfreq`
    python3 tools/build_en_table.py --report new_short_words.txt

Sources, merged in this order (see vocab/SOURCES.md for licenses):
1. The existing en_table.txt. Every entry is kept, with its capitalisation
   (GitHub, iPhone). Reads both the old format and the one written here, so
   the tool can be re-run on its own output.
2. vocab/en_supplement.txt: hand-written technical vocabulary.
3. wordfreq's English frequency list.

Length rule. Wubi codes are at most 4 letters, so every English word of 4
letters or fewer shares the keyboard with a wubi code. Those are added
sparingly: at least SHORT_WORD_MIN_LENGTH letters, in wordfreq's top
SHORT_WORD_MAX_RANK, and listed in the system dictionary (which keeps out
abbreviations like "nfl" and chat spellings like "dont").
Words of 5 letters or more cannot collide with wubi and are added freely,
down to rank LONG_WORD_MAX_RANK.

Output format, one entry per line, tab-separated:
    key <TAB> display form <TAB> frequency rank [<TAB> id salt]
`key` is what the user types: the display form lowercased, spaces removed.
`rank` is the 1-based wordfreq rank (smaller = more common); UNRANKED for
words wordfreq does not know. Two display forms of one key (august/August)
are two lines. `id salt` appears only on the few entries whose id would
otherwise collide with a more common word's; see word_id().
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

SHORT_WORD_MAX_LENGTH = 4
SHORT_WORD_MIN_LENGTH = 3
SHORT_WORD_MAX_RANK = 10_000
LONG_WORD_MAX_RANK = 80_000
RANK_LOOKUP_SIZE = 300_000
UNRANKED = 200_000
SUPPLEMENT_DEFAULT_RANK = 30_000

# Entry ids live in 0x40000000..0x7FFFFFFF: above every system dictionary
# entry, below the user-entry range that starts at 0x80000000.
# Must stay identical to EnglishWordIndex.wordId(key:display:) in Swift.
ID_BASE = 0x40000000
ID_MASK = 0x3FFFFFFF

WORDFREQ_TOKEN = re.compile(r"^[a-z]+(?:'[a-z]+)*$")
SYSTEM_WORDS = Path('/usr/share/dict/words')


def word_id(key: str, display: str, salt: str = '') -> int:
    """FNV-1a (32-bit) of "key<TAB>display<salt>", folded into the English id range.

    The id keys the word's learning record, so it has to be the same on every
    machine and survive words being added: it depends on nothing but the entry.
    """
    h = 0x811C9DC5
    for byte in f'{key}\t{display}{salt}'.encode('utf-8'):
        h ^= byte
        h = (h * 0x01000193) & 0xFFFFFFFF
    return ID_BASE | (h & ID_MASK)


def make_key(display: str) -> str:
    return display.lower().replace(' ', '')


def parse_existing(path: Path):
    """Yield (display, rank or None) from en_table.txt in either format."""
    if not path.exists():
        return
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or '&' in line:  # drops the stray "&nbsp;" entry
            continue
        parts = line.split('\t')
        if len(parts) < 2:
            continue

        # Format written by this tool: key, display, rank[, id salt].
        if len(parts) in (3, 4) and parts[2].isdigit():
            yield parts[1], int(parts[2])
            continue

        key, rest = parts[0].lower(), parts[1:]
        # Old format, several capitalisations of one word: august, August, august
        if all(p.lower() == key for p in rest):
            for display in dict.fromkeys(rest):
                yield display, None
            continue

        # Old format, a multi-word name written with tabs between its words:
        #   iphone, 11, pro, iPhone, 11, Pro   ->   "iPhone 11 Pro"
        half = len(parts) // 2
        if len(parts) % 2 == 0 and [p.lower() for p in parts[half:]] == [p.lower() for p in parts[:half]]:
            yield ' '.join(parts[half:]), None
            continue

        print(f'  skipped unreadable line: {raw!r}', file=sys.stderr)


def parse_supplement(path: Path):
    if not path.exists():
        return
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if line and not line.startswith('#'):
            yield line


def load_system_dictionary():
    """Return (words, names) from the system dictionary.

    words: every entry, lowercased. Used to vet short additions.
    names: entries listed only with a capital (London, Amazon), lowercased.
           wordfreq lowercases everything; this restores the capital.
    """
    if not SYSTEM_WORDS.exists():
        return set(), set()
    listed = set(SYSTEM_WORDS.read_text(encoding='utf-8', errors='ignore').split())
    names = {w.lower() for w in listed if w[:1].isupper() and w[1:].islower() and w.lower() not in listed}
    return {w.lower() for w in listed}, names


def build(existing_path: Path, supplement_path: Path, ranked_words, system_dictionary=None):
    """Return (entries, new_short_words).

    entries: list of (key, display, rank, id salt), sorted by key then rank.
    ranked_words: wordfreq's list, most common first.
    system_dictionary: (words, names) as from load_system_dictionary(); read
        from the system when not given.
    """
    rank_of = {w: i + 1 for i, w in enumerate(ranked_words)}
    dictionary_words, names = system_dictionary or load_system_dictionary()

    entries = {}  # (key, display) -> rank

    def add(display, rank):
        key = make_key(display)
        if not key:
            return False
        if (key, display) in entries:
            entries[(key, display)] = min(entries[(key, display)], rank)
            return False
        entries[(key, display)] = rank
        return True

    for display, rank in parse_existing(existing_path):
        add(display, rank if rank is not None else rank_of.get(display.lower(), UNRANKED))
    existing_keys = {key for key, _ in entries}

    for display in parse_supplement(supplement_path):
        if make_key(display) not in existing_keys:
            add(display, rank_of.get(display.lower(), SUPPLEMENT_DEFAULT_RANK))
    known_keys = {key for key, _ in entries}

    new_short_words = []
    for word in ranked_words[:LONG_WORD_MAX_RANK]:
        if word in known_keys or not WORDFREQ_TOKEN.match(word):
            continue
        rank = rank_of[word]
        is_short = len(word) <= SHORT_WORD_MAX_LENGTH
        if is_short and (rank > SHORT_WORD_MAX_RANK or len(word) < SHORT_WORD_MIN_LENGTH
                         or word not in dictionary_words):
            continue
        display = word.capitalize() if word in names else word
        if add(display, rank) and is_short:
            new_short_words.append((rank, display))

    # Two entries hashing to one id would share a learning record. The more
    # common word keeps the plain id; the other gets the smallest salt that
    # frees it, written to the table so the app derives the same id.
    taken, result = set(), []
    for (key, display), rank in sorted(entries.items(), key=lambda item: (item[1], item[0])):
        salt = ''
        while word_id(key, display, salt) in taken:
            salt = str(int(salt or '0') + 1)
        taken.add(word_id(key, display, salt))
        result.append((key, display, rank, salt))

    result.sort(key=lambda e: (e[0], e[2], e[1]))
    return result, new_short_words


def write_table(entries, path: Path):
    lines = (f'{k}\t{d}\t{r}\t{salt}\n' if salt else f'{k}\t{d}\t{r}\n' for k, d, r, salt in entries)
    path.write_text(''.join(lines), encoding='utf-8')


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description='Build vocab/en_table.txt from the existing table, the supplement and wordfreq.')
    parser.add_argument('--vocab', type=Path, default=root / 'vocab' / 'en_table.txt')
    parser.add_argument('--supplement', type=Path, default=root / 'vocab' / 'en_supplement.txt')
    parser.add_argument('--resources', type=Path, default=root / 'MarmotIM' / 'Resources' / 'en_table.txt')
    parser.add_argument('--report', type=Path, help='write the newly added short words here, for review')
    args = parser.parse_args()

    try:
        from wordfreq import top_n_list  # type: ignore[import-not-found]
    except ImportError:
        sys.exit('wordfreq is not installed. Run: pip install wordfreq')

    ranked_words = top_n_list('en', RANK_LOOKUP_SIZE)
    entries, new_short_words = build(args.vocab, args.supplement, ranked_words)

    write_table(entries, args.vocab)
    shutil.copyfile(args.vocab, args.resources)

    short = sum(1 for entry in entries if len(entry[0]) <= SHORT_WORD_MAX_LENGTH)
    salted = sum(1 for entry in entries if entry[3])
    print(f'Wrote {len(entries)} entries ({short} of them {SHORT_WORD_MAX_LENGTH} letters or fewer)')
    print(f'  {args.vocab}\n  {args.resources}')
    print(f'New short words added: {len(new_short_words)}')
    print(f'Entries given an id salt: {salted}')
    if args.report:
        args.report.write_text(''.join(f'{rank}\t{word}\n' for rank, word in sorted(new_short_words)), encoding='utf-8')
        print(f'  listed in {args.report}')


if __name__ == '__main__':
    main()
