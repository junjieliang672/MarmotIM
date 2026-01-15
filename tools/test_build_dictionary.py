#!/usr/bin/env python3
"""
Tests for dictionary builder - specifically the frecency sharing fix.

The fix ensures that the same text (e.g., "鬼") has only ONE entry in the database,
with all its wubi codes and pinyin codes pointing to the SAME entry_id.
This allows frecency scores to be shared across input methods.

Test cases based on user-reported bugs:
- 鬼: wubi "rqc", pinyin "gui" - should share same entry_id
- 毒: wubi "gxgu", pinyin "du" - should share same entry_id
"""

import os
import sys
import tempfile
import unittest

# Add parent directory to path to import build_dictionary
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from build_dictionary import (
    merge_dictionaries,
    build_indexes,
    SOURCE_WUBI,
    SOURCE_PINYIN,
    SOURCE_EXTRA_PINYIN,
)


class TestMergeDictionaries(unittest.TestCase):
    """Tests for merge_dictionaries function - text as unique key."""

    def test_same_text_from_wubi_and_pinyin_produces_one_entry(self):
        """Same text appearing in both wubi and pinyin should produce ONE entry."""
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': 'gui', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])

        # Should have only ONE entry for '鬼'
        gui_entries = [e for e in entries if e['text'] == '鬼']
        self.assertEqual(len(gui_entries), 1, "Should have exactly one entry for '鬼'")

        entry = gui_entries[0]
        # Entry should have both wubi and pinyin codes
        self.assertIn('rqc', entry['wubi_codes'])
        self.assertIn('gui', entry['pinyin_codes'])

    def test_mode_specific_base_frequencies(self):
        """Wubi and pinyin should have separate base frequencies."""
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': 'gui', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])
        entry = [e for e in entries if e['text'] == '鬼'][0]

        # Should have separate frequencies for each mode
        self.assertEqual(entry['wubi_base_frequency'], 35000, "Wubi base frequency should be preserved")
        self.assertEqual(entry['pinyin_base_frequency'], 65000, "Pinyin base frequency should be preserved")

    def test_multiple_wubi_codes_for_same_text_collected(self):
        """Multiple wubi codes for same text should be collected in one entry."""
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 45000, 'source': SOURCE_WUBI, 'length': 1},
            {'text': '鬼', 'wubi': 'rqci', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, [], [])

        gui_entries = [e for e in entries if e['text'] == '鬼']
        self.assertEqual(len(gui_entries), 1, "Should have exactly one entry for '鬼'")

        entry = gui_entries[0]
        self.assertIn('rqc', entry['wubi_codes'])
        self.assertIn('rqci', entry['wubi_codes'])

    def test_du_poison_has_one_entry(self):
        """毒 (du/gxgu) should have exactly one entry with both codes."""
        wubi_entries = [
            {'text': '毒', 'wubi': 'gxgu', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '毒', 'wubi': 'gxgu', 'pinyin': 'du', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])

        du_entries = [e for e in entries if e['text'] == '毒']
        self.assertEqual(len(du_entries), 1, "Should have exactly one entry for '毒'")

        entry = du_entries[0]
        self.assertIn('gxgu', entry['wubi_codes'])
        self.assertIn('du', entry['pinyin_codes'])

    def test_wubi_source_preserved_when_text_in_wubi_dict(self):
        """Text from wubi dict should have SOURCE_WUBI even if also in pinyin."""
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': 'gui', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])

        entry = [e for e in entries if e['text'] == '鬼'][0]
        self.assertEqual(entry['source'], SOURCE_WUBI)

    def test_best_wubi_frequency_preserved(self):
        """Highest wubi_base_frequency should be preserved when merging multiple wubi entries."""
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqci', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 45000, 'source': SOURCE_WUBI, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, [], [])

        entry = [e for e in entries if e['text'] == '鬼'][0]
        self.assertEqual(entry['wubi_base_frequency'], 45000)

    def test_pinyin_only_entry_has_pinyin_source(self):
        """Text only in pinyin dict should have SOURCE_PINYIN."""
        pinyin_entries = [
            {'text': '测试', 'wubi': None, 'pinyin': 'ceshi', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 2},
        ]

        entries = merge_dictionaries([], pinyin_entries, [])

        entry = [e for e in entries if e['text'] == '测试'][0]
        self.assertEqual(entry['source'], SOURCE_PINYIN)

    def test_extra_pinyin_lowest_priority(self):
        """Extra pinyin entries should only add new texts."""
        pinyin_entries = [
            {'text': 'hello', 'wubi': None, 'pinyin': 'hello', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 5},
        ]
        extra_entries = [
            {'text': 'hello', 'wubi': None, 'pinyin': 'hello', 'baseFrequency': 1000, 'source': SOURCE_EXTRA_PINYIN, 'length': 5},
            {'text': 'world', 'wubi': None, 'pinyin': 'world', 'baseFrequency': 1000, 'source': SOURCE_EXTRA_PINYIN, 'length': 5},
        ]

        entries = merge_dictionaries([], pinyin_entries, extra_entries)

        # 'hello' should have pinyin source (already existed)
        hello = [e for e in entries if e['text'] == 'hello'][0]
        self.assertEqual(hello['source'], SOURCE_PINYIN)

        # 'world' should have extra source (new)
        world = [e for e in entries if e['text'] == 'world'][0]
        self.assertEqual(world['source'], SOURCE_EXTRA_PINYIN)

    def test_unique_entry_ids_assigned(self):
        """Each entry should have a unique ID."""
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
            {'text': '毒', 'wubi': 'gxgu', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': 'gui', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
            {'text': '毒', 'wubi': 'gxgu', 'pinyin': 'du', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])

        ids = [e['id'] for e in entries]
        self.assertEqual(len(ids), len(set(ids)), "All entry IDs should be unique")


class TestBuildIndexes(unittest.TestCase):
    """Tests for build_indexes function - all codes point to same entry."""

    def test_wubi_and_pinyin_codes_point_to_same_entry(self):
        """Wubi code 'rqc' and pinyin code 'gui' should point to same entry_id for '鬼'."""
        entries = [{
            'id': 42,
            'text': '鬼',
            'wubi': 'rqc',
            'pinyin': 'gui',
            'baseFrequency': 35000,
            'source': SOURCE_WUBI,
            'length': 1,
            'wubi_codes': {'rqc', 'rqci'},
            'pinyin_codes': {'gui'},
        }]

        pinyin_index, wubi_index = build_indexes(entries)

        # Both should point to entry 42
        self.assertIn(42, wubi_index.get('rqc', []))
        self.assertIn(42, wubi_index.get('rqci', []))
        self.assertIn(42, pinyin_index.get('gui', []))

    def test_du_poison_indexes_point_to_same_entry(self):
        """Wubi 'gxgu' and pinyin 'du' should point to same entry_id for '毒'."""
        entries = [{
            'id': 100,
            'text': '毒',
            'wubi': 'gxgu',
            'pinyin': 'du',
            'baseFrequency': 35000,
            'source': SOURCE_WUBI,
            'length': 1,
            'wubi_codes': {'gxgu'},
            'pinyin_codes': {'du'},
        }]

        pinyin_index, wubi_index = build_indexes(entries)

        self.assertIn(100, wubi_index.get('gxgu', []))
        self.assertIn(100, pinyin_index.get('du', []))

    def test_wubi_index_only_for_wubi_source(self):
        """Wubi codes should only be indexed for SOURCE_WUBI entries."""
        entries = [{
            'id': 1,
            'text': '测试',
            'wubi': 'ybig',
            'pinyin': 'ceshi',
            'baseFrequency': 65000,
            'source': SOURCE_PINYIN,  # Not from wubi dict
            'length': 2,
            'wubi_codes': {'ybig'},
            'pinyin_codes': {'ceshi'},
        }]

        pinyin_index, wubi_index = build_indexes(entries)

        # Should NOT be in wubi index since source is PINYIN
        self.assertNotIn('ybig', wubi_index)
        # Should be in pinyin index
        self.assertIn(1, pinyin_index.get('ceshi', []))

    def test_all_pinyin_codes_indexed(self):
        """All pinyin codes for an entry should be indexed."""
        entries = [{
            'id': 1,
            'text': '长',
            'wubi': 'ta',
            'pinyin': 'chang',
            'baseFrequency': 65000,
            'source': SOURCE_WUBI,
            'length': 1,
            'wubi_codes': {'ta', 'tayi'},
            'pinyin_codes': {'chang', 'zhang'},  # Multiple pronunciations
        }]

        pinyin_index, wubi_index = build_indexes(entries)

        self.assertIn(1, pinyin_index.get('chang', []))
        self.assertIn(1, pinyin_index.get('zhang', []))

    def test_all_wubi_codes_indexed(self):
        """All wubi codes for an entry should be indexed."""
        entries = [{
            'id': 1,
            'text': '鬼',
            'wubi': 'rqc',
            'pinyin': 'gui',
            'baseFrequency': 35000,
            'source': SOURCE_WUBI,
            'length': 1,
            'wubi_codes': {'rqc', 'rqci'},  # Multiple wubi codes
            'pinyin_codes': {'gui'},
        }]

        pinyin_index, wubi_index = build_indexes(entries)

        self.assertIn(1, wubi_index.get('rqc', []))
        self.assertIn(1, wubi_index.get('rqci', []))


class TestFrecencySharingIntegration(unittest.TestCase):
    """Integration tests for frecency sharing across input methods."""

    def test_gui_ghost_frecency_shared(self):
        """
        User story: Select '鬼' via wubi 'rqc', then search via pinyin 'gui'.
        The frecency score should apply to the same entry.
        """
        wubi_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
            {'text': '鬼', 'wubi': 'rqci', 'pinyin': '', 'baseFrequency': 34000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '鬼', 'wubi': 'rqc', 'pinyin': 'gui', 'baseFrequency': 55000, 'source': SOURCE_PINYIN, 'length': 1},
            {'text': '归', 'wubi': 'jvg', 'pinyin': 'gui', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
            {'text': '贵', 'wubi': 'khgm', 'pinyin': 'gui', 'baseFrequency': 64500, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])
        pinyin_index, wubi_index = build_indexes(entries)

        # Find '鬼' entry
        gui_ghost = [e for e in entries if e['text'] == '鬼'][0]
        gui_ghost_id = gui_ghost['id']

        # Verify wubi 'rqc' and pinyin 'gui' both point to same entry
        wubi_rqc_ids = wubi_index.get('rqc', [])
        pinyin_gui_ids = pinyin_index.get('gui', [])

        self.assertIn(gui_ghost_id, wubi_rqc_ids, "'鬼' should be found via wubi 'rqc'")
        self.assertIn(gui_ghost_id, pinyin_gui_ids, "'鬼' should be found via pinyin 'gui'")

    def test_du_poison_frecency_shared(self):
        """
        User story: Select '毒' via wubi 'gxgu', then search via pinyin 'du'.
        The frecency score should apply to the same entry.
        """
        wubi_entries = [
            {'text': '毒', 'wubi': 'gxgu', 'pinyin': '', 'baseFrequency': 35000, 'source': SOURCE_WUBI, 'length': 1},
        ]
        pinyin_entries = [
            {'text': '毒', 'wubi': 'gxgu', 'pinyin': 'du', 'baseFrequency': 55000, 'source': SOURCE_PINYIN, 'length': 1},
            {'text': '读', 'wubi': 'yond', 'pinyin': 'du', 'baseFrequency': 65000, 'source': SOURCE_PINYIN, 'length': 1},
            {'text': '度', 'wubi': 'yaci', 'pinyin': 'du', 'baseFrequency': 64500, 'source': SOURCE_PINYIN, 'length': 1},
        ]

        entries = merge_dictionaries(wubi_entries, pinyin_entries, [])
        pinyin_index, wubi_index = build_indexes(entries)

        # Find '毒' entry
        du_poison = [e for e in entries if e['text'] == '毒'][0]
        du_poison_id = du_poison['id']

        # Verify wubi 'gxgu' and pinyin 'du' both point to same entry
        wubi_gxgu_ids = wubi_index.get('gxgu', [])
        pinyin_du_ids = pinyin_index.get('du', [])

        self.assertIn(du_poison_id, wubi_gxgu_ids, "'毒' should be found via wubi 'gxgu'")
        self.assertIn(du_poison_id, pinyin_du_ids, "'毒' should be found via pinyin 'du'")


if __name__ == '__main__':
    unittest.main()
