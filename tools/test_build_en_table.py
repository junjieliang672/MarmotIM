#!/usr/bin/env python3
"""Tests for tools/build_en_table.py, the English word table builder."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from build_en_table import (
    ID_BASE,
    LONG_WORD_MAX_RANK,
    SHORT_WORD_MAX_RANK,
    UNRANKED,
    build,
    parse_existing,
    word_id,
    write_table,
)


class BuildEnTableTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.existing = self.dir / 'en_table.txt'
        self.supplement = self.dir / 'en_supplement.txt'
        self.supplement.write_text('# comment\nasync\n', encoding='utf-8')

    def build(self, existing_lines, ranked_words, dictionary=((), ())):
        self.existing.write_text('\n'.join(existing_lines) + '\n', encoding='utf-8')
        words, names = dictionary
        return build(self.existing, self.supplement, ranked_words, (set(words), set(names)))

    def test_old_format_lines_are_read(self):
        self.existing.write_text('\n'.join([
            'github\tGitHub',
            'august\tAugust\taugust',
            'iphone\t11\tpro\tiPhone\t11\tPro',
            '&nbsp;\t&nbsp;',
        ]) + '\n', encoding='utf-8')
        self.assertEqual(
            [display for display, _ in parse_existing(self.existing)],
            ['GitHub', 'August', 'august', 'iPhone 11 Pro'])

    def test_existing_entries_keep_capitalisation_and_get_a_rank(self):
        entries, _ = self.build(['github\tGitHub', 'iphone\t11\tpro\tiPhone\t11\tPro'], ['the', 'github'])
        table = {(key, display): rank for key, display, rank, _ in entries}
        self.assertEqual(table[('github', 'GitHub')], 2)
        self.assertEqual(table[('iphone11pro', 'iPhone 11 Pro')], UNRANKED)

    def test_long_words_are_added_freely(self):
        ranked = ['filler%d' % i for i in range(LONG_WORD_MAX_RANK - 1)] + ['zeitgeist', 'toolate']
        entries, _ = self.build([], ranked)
        keys = {key for key, _, _, _ in entries}
        self.assertIn('zeitgeist', keys)
        self.assertNotIn('toolate', keys, 'past LONG_WORD_MAX_RANK')
        self.assertNotIn('filler0', keys, 'digits are not a word')

    def test_short_words_need_rank_length_and_dictionary(self):
        ranked = ['arm', 'nfl', 'ox'] + ['pad%s' % ('x' * (i % 3 + 5)) for i in range(SHORT_WORD_MAX_RANK)] + ['yak']
        entries, new_short = self.build([], ranked, dictionary=(['arm', 'ox', 'yak'], []))
        keys = {key for key, _, _, _ in entries}
        self.assertIn('arm', keys)
        self.assertNotIn('nfl', keys, 'not in the dictionary')
        self.assertNotIn('ox', keys, 'two letters')
        self.assertNotIn('yak', keys, 'past SHORT_WORD_MAX_RANK')
        self.assertEqual([word for _, word in new_short], ['arm'])

    def test_existing_short_words_are_all_kept(self):
        entries, new_short = self.build(['nfl\tNFL', 'ox\tox'], ['the'], dictionary=([], []))
        self.assertEqual({key for key, _, _, _ in entries} & {'nfl', 'ox'}, {'nfl', 'ox'})
        self.assertEqual(new_short, [])

    def test_names_get_their_capital_back(self):
        entries, _ = self.build([], ['london'], dictionary=(['london'], ['london']))
        self.assertIn(('london', 'London'), {(key, display) for key, display, _, _ in entries})

    def test_supplement_words_are_added_when_missing(self):
        entries, _ = self.build([], ['the'])
        self.assertIn('async', {key for key, _, _, _ in entries})

    def test_rebuilding_from_its_own_output_changes_nothing(self):
        ranked = ['the', 'kubernetes', 'github']
        entries, _ = self.build(['github\tGitHub', 'august\tAugust\taugust'], ranked)
        write_table(entries, self.existing)
        first = self.existing.read_text(encoding='utf-8')
        again, _ = build(self.existing, self.supplement, ranked, (set(), set()))
        write_table(again, self.existing)
        self.assertEqual(self.existing.read_text(encoding='utf-8'), first)

    def test_word_ids(self):
        # The same values are pinned in MarmotIMTests/EnglishWordIndexTests.swift
        self.assertEqual(word_id('github', 'GitHub'), 0x5e9c86f6)
        self.assertEqual(word_id('cleaners', 'cleaners', '1'), 0x6d1f61ed)
        self.assertTrue(ID_BASE <= word_id('the', 'the') < 0x80000000)


class ShippedTableTest(unittest.TestCase):
    """Checks on the table that is actually in the repository."""

    ROOT = Path(__file__).resolve().parent.parent

    def rows(self):
        text = (self.ROOT / 'vocab' / 'en_table.txt').read_text(encoding='utf-8')
        return [line.split('\t') for line in text.splitlines()]

    def test_every_line_is_key_display_rank(self):
        for row in self.rows():
            self.assertIn(len(row), (3, 4), row)
            self.assertEqual(row[0], row[1].lower().replace(' ', ''), row)
            self.assertTrue(row[2].isdigit(), row)

    def test_ids_are_unique(self):
        ids = [word_id(row[0], row[1], row[3] if len(row) > 3 else '') for row in self.rows()]
        self.assertEqual(len(ids), len(set(ids)))

    def test_bundle_copy_matches(self):
        vocab = (self.ROOT / 'vocab' / 'en_table.txt').read_bytes()
        bundle = (self.ROOT / 'MarmotIM' / 'Resources' / 'en_table.txt').read_bytes()
        self.assertEqual(vocab, bundle)

    def test_multi_word_names_are_no_longer_split(self):
        by_key = {}
        for row in self.rows():
            by_key.setdefault(row[0], []).append(row[1])
        self.assertEqual(by_key['iphone'], ['iPhone'])
        self.assertEqual(by_key['windows'], ['Windows'])


if __name__ == '__main__':
    unittest.main()
