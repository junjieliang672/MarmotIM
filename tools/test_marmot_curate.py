#!/usr/bin/env python3
"""Tests for tools/marmot_curate.py against synthetic behaviour logs."""

import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import marmot_curate as mc  # noqa: E402

DAY = 86400

EVENTS_DDL = """
    CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL, app TEXT, code TEXT,
        code_type TEXT, text TEXT, rank INTEGER, trigger TEXT, page INTEGER, candidates TEXT, n INTEGER)
"""


class CurateTestCase(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.behavior_db = os.path.join(self.tmp.name, 'behavior.db')
        self.dictionary_db = os.path.join(self.tmp.name, 'dictionary.db')
        self.now = time.time()

        conn = sqlite3.connect(self.behavior_db)
        conn.execute(EVENTS_DDL)
        conn.commit()
        conn.close()

        conn = sqlite3.connect(self.dictionary_db)
        conn.executescript("""
            CREATE TABLE entries (id INTEGER PRIMARY KEY, text TEXT NOT NULL);
            CREATE TABLE user_learning (entry_id INTEGER PRIMARY KEY, access_count INTEGER,
                                        last_access_timestamp INTEGER, total_score REAL);
            CREATE TABLE user_favorites (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE,
                                         wubi_code TEXT, pinyin_code TEXT, added_timestamp INTEGER,
                                         is_deleted INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE user_suppressed_words (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE,
                                                suppressed_timestamp INTEGER, is_deleted INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE user_relative_order (id INTEGER PRIMARY KEY AUTOINCREMENT, word_a TEXT, word_b TEXT,
                                              created_at INTEGER, updated_at INTEGER,
                                              is_deleted INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE char_to_wubi (char TEXT PRIMARY KEY, wubi_code TEXT NOT NULL);
            CREATE TABLE char_to_pinyin (char TEXT, pinyin TEXT, is_primary INTEGER, PRIMARY KEY (char, pinyin));
            CREATE TABLE polyphone_words (word TEXT PRIMARY KEY, pinyin TEXT);
            CREATE TABLE sync_counter_state (payload TEXT, key TEXT, device_id TEXT, count INTEGER,
                                             PRIMARY KEY (payload, key, device_id));
        """)
        conn.executemany("INSERT INTO char_to_wubi VALUES (?, ?)",
                         [('输', 'lwgj'), ('入', 'tyi'), ('法', 'ifcy'), ('交', 'uqu'), ('集', 'wysu')])
        conn.executemany("INSERT INTO char_to_pinyin VALUES (?, ?, 1)",
                         [('输', 'shu'), ('入', 'ru'), ('法', 'fa'), ('交', 'jiao'), ('集', 'ji')])
        conn.executemany("INSERT INTO entries (id, text) VALUES (?, ?)",
                         [(1, '输入'), (2, '法'), (3, '的时候'), (4, '我'), (5, '交集'), (6, '效仿')])
        conn.commit()
        conn.close()

    def tearDown(self):
        self.tmp.cleanup()

    # -- fixtures ----------------------------------------------------------

    def add(self, kind, ts, **fields):
        fields.setdefault('app', 'com.apple.TextEdit')
        candidates = fields.pop('candidates', None)
        if candidates is not None:
            fields['candidates'] = json.dumps(
                [{'t': c[0], 'b': bool(c[1]) if len(c) > 1 else False, 'j': bool(c[2]) if len(c) > 2 else False}
                 for c in candidates], ensure_ascii=False)
        columns = ['kind', 'ts'] + list(fields)
        conn = sqlite3.connect(self.behavior_db)
        conn.execute(f"INSERT INTO events ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                     [kind, ts] + list(fields.values()))
        conn.commit()
        conn.close()

    def select(self, text, ts, code='xx', candidates=None, **fields):
        self.add('select', ts, text=text, code=code, code_type='wubi', rank=0, trigger='space', page=0,
                 candidates=candidates if candidates is not None else [(text,)], **fields)

    def sentence(self, words, ts):
        """Words picked one after another, one second apart, then punctuation"""
        for i, (word, code) in enumerate(words):
            self.select(word, ts + i, code=code)
        self.add('break', ts + len(words), trigger='punct')

    def run_cli(self, *argv):
        import io
        from contextlib import redirect_stdout
        out = io.StringIO()
        with redirect_stdout(out):
            code = mc.main(['--behavior-db', self.behavior_db, '--dictionary-db', self.dictionary_db, *argv])
        return code, json.loads(out.getvalue())

    def dictionary(self, sql, params=()):
        conn = sqlite3.connect(self.dictionary_db)
        conn.execute(sql, params)
        conn.commit()
        conn.close()


class UserDictCandidates(CurateTestCase):

    def test_consecutive_commits_become_a_phrase_candidate(self):
        for day in range(5):
            for n in range(4):
                self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - day * DAY - n * 100)
        _, out = self.run_cli('candidates', 'user-dict')

        phrase = next(c for c in out['phrases'] if c['text'] == '输入法')
        self.assertEqual(phrase['count'], 20)
        self.assertEqual(phrase['days'], 5)
        self.assertEqual(phrase['typed_as'], ['输入', '法'])
        self.assertEqual(phrase['cohesion'], 1.0)
        self.assertEqual(phrase['wubi'], 'ltif')
        self.assertEqual(phrase['pinyin'], 'shurufa')
        # Typed as lwty+space and if+space = 8 keys; as one word ltif+space = 5
        self.assertEqual(phrase['keys_saved_per_use'], 3.0)
        self.assertIn('【输入法】', phrase['contexts'][0])

    def test_weak_evidence_is_not_output(self):
        self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - 100)
        self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - 200)
        _, out = self.run_cli('candidates', 'user-dict')
        self.assertEqual(out['phrases'], [])

    def test_words_already_in_the_dictionary_are_skipped(self):
        self.dictionary("INSERT INTO entries (id, text) VALUES (9, '输入法')")
        for day in range(3):
            for n in range(3):
                self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - day * DAY - n * 100)
        _, out = self.run_cli('candidates', 'user-dict')
        self.assertEqual(out['phrases'], [])

    def test_pause_app_switch_and_punctuation_break_a_run(self):
        for day in range(3):
            base = self.now - day * DAY
            for n in range(3):
                t = base - n * 100
                self.select('输入', t, code='lwty')
                self.select('法', t + 60, code='if')           # A minute later
                self.select('输入', t + 70, code='lwty')
                self.add('break', t + 71, trigger='punct')      # Punctuation in between
                self.select('法', t + 72, code='if')
                self.select('输入', t + 80, code='lwty', app='com.a')
                self.select('法', t + 81, code='if', app='com.b')  # Another app
        _, out = self.run_cli('candidates', 'user-dict')
        self.assertFalse(any(c['text'] == '输入法' for c in out['phrases']))

    def test_fragment_has_low_cohesion_and_fixed_neighbours(self):
        for day in range(3):
            for n in range(3):
                t = self.now - day * DAY - n * 100
                self.sentence([('的时候', 'rjwn'), ('我', 'q')], t)
                # Both pieces are used far more often apart than together
                for k in range(5):
                    self.sentence([('我', 'q')], t - 30 - k * 3)
                    self.sentence([('的时候', 'rjwn')], t - 60 - k * 3)
        _, out = self.run_cli('candidates', 'user-dict')
        fragment = next(c for c in out['phrases'] if c['text'] == '的时候我')
        self.assertLess(fragment['cohesion'], 1.0)
        self.assertEqual(fragment['left_entropy'], 0.0, 'always starts the run: fixed left neighbour')

    def test_english_raw_commits(self):
        for day in range(3):
            self.add('raw', self.now - day * DAY, text='marmotctl', trigger='shift', n=0)
            self.add('raw', self.now - day * DAY - 5, text='the', trigger='shift', n=0)
        _, out = self.run_cli('candidates', 'user-dict')
        texts = [c['text'] for c in out['english']]
        self.assertIn('marmotctl', texts)
        self.assertNotIn('the', texts, 'already in en_table.txt')
        self.assertTrue(next(c for c in out['english'] if c['text'] == 'marmotctl')['english'])

    def test_secret_looking_strings_never_appear(self):
        secrets = ['sk-ant-abc123def456', 'hunter2hunter2X9', '13800138000', 'me@example.com',
                   'ghp_16C7e42F292c6912E7710c838347Ae178B4a']
        for secret in secrets:
            for day in range(3):
                self.add('raw', self.now - day * DAY, text=secret, trigger='enter', n=0)
        _, out = self.run_cli('candidates', 'user-dict')
        dumped = json.dumps(out, ensure_ascii=False)
        for secret in secrets:
            self.assertNotIn(secret, dumped)

    def test_no_context_and_limit(self):
        for day in range(3):
            for n in range(3):
                self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - day * DAY - n * 100)
                self.sentence([('交', 'uq'), ('集', 'wy')], self.now - day * DAY - n * 100 - 50)
        _, out = self.run_cli('candidates', 'user-dict', '--no-context', '--limit', '1')
        self.assertEqual(len(out['phrases']), 1)
        self.assertNotIn('contexts', out['phrases'][0])


class SuppressCandidates(CurateTestCase):

    def test_word_first_by_learning_but_skipped(self):
        for day in range(3):
            for n in range(3):
                # 效仿 leads through learning boosts; the user reaches past it for 交集
                self.select('交集', self.now - day * DAY - n * 10, code='uqwy',
                            candidates=[('效仿', True), ('交集',)])
            self.select('效仿', self.now - day * DAY - 500, code='uqwy', candidates=[('效仿', True), ('交集',)])
        _, out = self.run_cli('candidates', 'suppress')

        item = next(c for c in out['suppress'] if c['text'] == '效仿')
        self.assertEqual(item['shown_first_by_learning'], 12)
        self.assertEqual(item['skipped_when_first_by_learning'], 9)
        self.assertEqual(item['skip_rate_by_learning'], 0.75)
        self.assertEqual(item['times_picked'], 3)
        self.assertEqual(item['picked_instead'], {'交集': 9})

    def test_word_first_on_its_own_merit_is_not_a_candidate(self):
        for day in range(3):
            for n in range(3):
                self.select('交集', self.now - day * DAY - n * 10, code='uqwy',
                            candidates=[('效仿', False), ('交集',)])
        _, out = self.run_cli('candidates', 'suppress')
        self.assertEqual(out['suppress'], [], 'suppression only removes learning boosts')

    def test_already_suppressed_words_are_skipped(self):
        self.dictionary("INSERT INTO user_suppressed_words (text, suppressed_timestamp) VALUES ('效仿', 1)")
        for day in range(3):
            for n in range(3):
                self.select('交集', self.now - day * DAY - n * 10, code='uqwy',
                            candidates=[('效仿', True), ('交集',)])
        _, out = self.run_cli('candidates', 'suppress')
        self.assertEqual(out['suppress'], [])


class OrderCandidates(CurateTestCase):

    def shown(self, picked, above, ts):
        """`above` is ranked first, the other second"""
        other = '交集' if above == '效仿' else '效仿'
        self.select(picked, ts, code='uqwy', candidates=[(above,), (other,)])

    def test_stable_preference(self):
        for day in range(4):
            base = self.now - day * DAY
            for n in range(4):
                self.shown('交集', '效仿', base - n * 10)     # 效仿 above, picks 交集
            self.shown('交集', '交集', base - 100)            # 交集 above, picks 交集
        self.shown('效仿', '交集', self.now - 5 * DAY)
        self.shown('效仿', '效仿', self.now - 5 * DAY - 10)
        _, out = self.run_cli('candidates', 'order')

        pair = out['order'][0]
        self.assertEqual((pair['a'], pair['b']), ('交集', '效仿'))
        self.assertEqual(pair['shown_together'], 22)
        self.assertEqual(pair['picked_a'], 20)
        self.assertEqual(pair['picked_a_past_b'], 16)
        self.assertEqual(pair['a_share'], 0.91)
        self.assertGreater(pair['order_flips'], 0)

    def test_pair_already_in_the_right_order_is_not_a_candidate(self):
        for day in range(4):
            for n in range(4):
                self.shown('交集', '交集', self.now - day * DAY - n * 10)
        _, out = self.run_cli('candidates', 'order')
        self.assertEqual(out['order'], [], 'the user never had to reach past the other word')

    def test_jianma_existing_rule_and_cycle_are_excluded(self):
        def many(candidates_for, code):
            for day in range(4):
                for n in range(4):
                    self.select(candidates_for[1][0], self.now - day * DAY - n * 10, code=code,
                                candidates=candidates_for)
        many([('工', False, True), ('戈',)], 'a')                 # Involves a protected short code
        many([('甲',), ('乙',)], 'jia')                           # Rule 乙→甲 exists already
        many([('丙',), ('丁',)], 'bing')                          # 丁→丙 would close 丙→戊→丁→丙
        self.dictionary("INSERT INTO user_relative_order (word_a, word_b) VALUES ('乙', '甲')")
        self.dictionary("INSERT INTO user_relative_order (word_a, word_b) VALUES ('丙', '戊')")
        self.dictionary("INSERT INTO user_relative_order (word_a, word_b) VALUES ('戊', '丁')")
        _, out = self.run_cli('candidates', 'order')
        self.assertEqual(out['order'], [])


class Decisions(CurateTestCase):

    def decide(self, decisions):
        path = os.path.join(self.tmp.name, 'decisions.json')
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(decisions, f, ensure_ascii=False)
        return self.run_cli('decide', '--file', path, '--no-notify')

    def test_decisions_are_recorded(self):
        code, out = self.decide([
            {'kind': 'add_word', 'decision': 'accept', 'text': '输入法', 'wubi': 'ltif', 'pinyin': 'shurufa',
             'reason': '常用名词', 'stats': {'count': 20}},
            {'kind': 'add_rule', 'decision': 'reject', 'a': '交集', 'b': '效仿', 'stats': {'count': 10}},
        ])
        self.assertEqual(code, 0)
        self.assertEqual([r['status'] for r in out['results']], ['accepted', 'rejected'])
        self.assertIn('尚未生效', out['note'])

        _, history = self.run_cli('history')
        self.assertEqual(history['proposals'][0]['payload'], {'text': '输入法', 'wubi': 'ltif', 'pinyin': 'shurufa'})
        self.assertEqual(history['proposals'][0]['stats']['learning_at_decision'], 0)

    def test_invalid_decisions_write_nothing(self):
        code, out = self.decide([
            {'kind': 'add_word', 'decision': 'accept', 'text': '输入法'},                    # No code
            {'kind': 'add_word', 'decision': 'accept', 'text': '输入法', 'wubi': 'TOOLONG'},
            {'kind': 'add_rule', 'decision': 'accept', 'a': '交集', 'b': '交集'},
            {'kind': 'bogus', 'decision': 'accept', 'text': 'x'},
            {'kind': 'suppress', 'decision': 'maybe', 'text': '效仿'},
        ])
        self.assertEqual(code, 1)
        self.assertEqual(len(out['invalid']), 5)
        _, history = self.run_cli('history')
        self.assertEqual(history['proposals'], [])

    def test_rejected_suggestion_returns_only_when_evidence_doubles(self):
        def type_it(times, offset):
            for i in range(times):
                self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - (i % 3) * DAY - offset - i * 20)

        type_it(6, 0)
        _, out = self.run_cli('candidates', 'user-dict')
        self.assertEqual(out['phrases'][0]['count'], 6)

        self.decide([{'kind': 'add_word', 'decision': 'reject', 'text': '输入法', 'stats': {'count': 6}}])
        type_it(3, 1000)
        _, out = self.run_cli('candidates', 'user-dict')
        self.assertEqual(out['phrases'], [], '9 uses: not yet double the 6 it was rejected at')

        type_it(3, 2000)
        _, out = self.run_cli('candidates', 'user-dict')
        self.assertEqual(out['phrases'][0]['count'], 12)


class ExitCandidates(CurateTestCase):

    def applied(self, kind, payload, days_ago, stats=None):
        conn = sqlite3.connect(self.behavior_db)
        conn.execute(mc.PROPOSALS_DDL)
        when = self.now - days_ago * DAY
        key = mc.proposal_key(kind, payload)
        conn.execute("INSERT INTO proposals (kind, key, payload, status, stats, decided_at, applied_at) "
                     "VALUES (?, ?, ?, 'applied', ?, ?, ?)",
                     (kind, key, json.dumps(payload, ensure_ascii=False), json.dumps(stats or {}), when, when))
        conn.commit()
        conn.close()

    def test_added_word_use_counts_every_mac(self):
        self.applied('add_word', {'text': '输入法', 'wubi': 'ltif'}, 20, {'learning_at_decision': 1})
        self.dictionary("INSERT INTO user_favorites (text, wubi_code) VALUES ('输入法', 'ltif')")
        # Never picked on this Mac, but 7 times on another one
        self.dictionary("INSERT INTO sync_counter_state VALUES ('learning', '输入法', 'legacy-v1', 1)")
        self.dictionary("INSERT INTO sync_counter_state VALUES ('learning', '输入法', 'OTHER-MAC', 7)")
        self.select('输入', self.now - DAY, code='lt', candidates=[('输入',), ('输入法',)])
        _, out = self.run_cli('candidates', 'exit')

        item = out['exit'][0]
        self.assertEqual(item['kind'], 'remove_word')
        self.assertEqual(item['picked_since_all_macs'], 7)
        self.assertEqual(item['picked_since_this_mac'], 0)
        self.assertEqual(item['shown_but_skipped_this_mac'], 1)

    def test_words_the_user_added_or_removed_by_hand_are_not_exit_candidates(self):
        # Added by hand: no applied proposal for it
        self.dictionary("INSERT INTO user_favorites (text, wubi_code) VALUES ('手动词', 'rfud')")
        # Added through this tool, then deleted by hand
        self.applied('add_word', {'text': '输入法', 'wubi': 'ltif'}, 20)
        self.dictionary("INSERT INTO user_favorites (text, wubi_code, is_deleted) VALUES ('输入法', 'ltif', 1)")
        _, out = self.run_cli('candidates', 'exit')
        self.assertEqual(out['exit'], [])

    def test_suppressed_word_the_user_keeps_picking(self):
        self.applied('suppress', {'text': '效仿'}, 10)
        self.dictionary("INSERT INTO user_suppressed_words (text, suppressed_timestamp) VALUES ('效仿', 1)")
        for n in range(4):
            self.select('效仿', self.now - DAY - n * 10, code='uqwy', candidates=[('交集',), ('效仿',)])
        self.select('交集', self.now - DAY - 100, code='uqwy', candidates=[('交集',), ('效仿',)])
        _, out = self.run_cli('candidates', 'exit')
        self.assertEqual(out['exit'][0]['kind'], 'unsuppress')
        self.assertEqual(out['exit'][0]['picked_since'], 4)
        self.assertEqual(out['exit'][0]['share_at_its_codes'], 0.8)

    def test_rule_the_user_now_contradicts(self):
        self.applied('add_rule', {'a': '交集', 'b': '效仿'}, 10)
        self.dictionary("INSERT INTO user_relative_order (word_a, word_b) VALUES ('交集', '效仿')")
        for n in range(3):
            self.select('效仿', self.now - DAY - n * 10, code='uqwy', candidates=[('交集',), ('效仿',)])
        self.select('交集', self.now - DAY - 100, code='uqwy', candidates=[('交集',), ('效仿',)])
        _, out = self.run_cli('candidates', 'exit')
        self.assertEqual(out['exit'][0]['kind'], 'remove_rule')
        self.assertEqual(out['exit'][0]['b_share_since'], 0.75)


class StatusAndCurrent(CurateTestCase):

    def test_status_without_a_log(self):
        os.remove(self.behavior_db)
        _, out = self.run_cli('status')
        self.assertFalse(out['recording'])
        self.assertEqual(out['events'], 0)

    def test_status_counts(self):
        self.sentence([('输入', 'lwty'), ('法', 'if')], self.now - DAY)
        self.sentence([('输入', 'lwty')], self.now)
        _, out = self.run_cli('status')
        self.assertEqual(out['events'], 5)
        self.assertEqual(out['by_kind'], {'select': 3, 'break': 2})

    def test_current_lists_only_active_rows(self):
        self.dictionary("INSERT INTO user_favorites (text, wubi_code) VALUES ('涉政', 'ihgh')")
        self.dictionary("INSERT INTO user_favorites (text, wubi_code, is_deleted) VALUES ('肓扫', 'yerv', 1)")
        self.dictionary("INSERT INTO user_suppressed_words (text, suppressed_timestamp) VALUES ('效仿', 1)")
        self.dictionary("INSERT INTO user_relative_order (word_a, word_b) VALUES ('次', '交集')")
        _, out = self.run_cli('current')
        self.assertEqual([w['text'] for w in out['user_words']], ['涉政'])
        self.assertEqual(out['suppressed'], ['效仿'])
        self.assertEqual(out['rules'], [{'a': '次', 'b': '交集'}])


if __name__ == '__main__':
    unittest.main()
