#!/usr/bin/env python3
"""
Dictionary Builder for MarmotIM
Builds a unified mixed Wubi+Pinyin dictionary with SQLite indexing.

Usage:
    python3 tools/build_dictionary.py           # Run with defaults (recommended)
    python3 tools/build_dictionary.py --no-install  # Build without installing

All vocab files should be in vocab/ directory. The script will:
1. Build the main dictionary from py_table.txt and wb_table.txt
2. Build filter indexes (emoji, fuzzy pinyin, symbols)
3. Install to ~/Library/Application Support/MarmotIM/
4. PRESERVE user data (user_learning, user_favorites, filter_user_freq)

Priority:
1. wb_table.txt entries (higher priority)
2. py_table.txt entries (lower priority)
3. Extra pinyin dictionaries (cn_en, en, emoji) with base score 1000

Output:
- dictionary.db: SQLite indexed dictionary with all filter indexes
"""

import argparse
import json
import math
import os
import shutil
import sqlite3
import struct
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Note: Symbol dictionary building requires PyYAML: pip install pyyaml
try:
    import yaml
    YAML_AVAILABLE = True
except ImportError:
    yaml = None  # type: ignore
    YAML_AVAILABLE = False


# Source priority: Wubi entries rank higher
SOURCE_WUBI = 1
SOURCE_PINYIN = 2
SOURCE_EXTRA_PINYIN = 3  # cn_en, en, emoji


def load_wubi_dict(filepath: str) -> List[dict]:
    """
    Load all entries from wb_table.txt.
    Format: code word1 word2 ...

    Returns list of entries with wubi code and high priority.

    Frequency priority:
    1. Shorter code = much higher priority (简码优先)
    2. First word in line = higher priority
    3. Line number has minimal effect
    """
    entries = []
    line_num = 0

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 2:
                continue

            code = parts[0]
            words = parts[1:]

            for word_idx, word in enumerate(words):
                # CRITICAL: Shorter codes get MUCH higher priority
                # 1-char code (简码): 60000+
                # 2-char code: 50000+
                # 3-char code: 40000+
                # 4-char code: 30000+
                code_len = len(code)
                if code_len == 1:
                    base_freq = 65000  # 一级简码 highest priority
                elif code_len == 2:
                    base_freq = 55000  # 二级简码
                elif code_len == 3:
                    base_freq = 45000  # 三级简码
                else:
                    base_freq = 35000  # 四码

                # First word in line gets priority
                base_freq -= word_idx * 100

                # Slight decrease for later lines (minimal effect)
                base_freq -= min(line_num // 100, 5000)

                base_freq = max(1, min(65535, base_freq))

                entries.append({
                    'text': word,
                    'wubi': code,
                    'pinyin': '',
                    'baseFrequency': base_freq,
                    'source': SOURCE_WUBI,
                    'length': len(word)
                })

            line_num += 1

            if line_num % 50000 == 0:
                print(f"  Loaded {line_num} wubi lines...")

    print(f"  Total: {len(entries)} wubi entries")
    return entries


def load_wubi_char_table(filepath: str) -> Dict[str, str]:
    """
    Load character to Wubi code mapping for generating wubi codes.
    Returns: dict mapping single character -> longest wubi code
    """
    char_to_code: Dict[str, str] = {}

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 2:
                continue

            code = parts[0]
            words = parts[1:]

            for word in words:
                if len(word) == 1:
                    if word not in char_to_code or len(code) > len(char_to_code[word]):
                        char_to_code[word] = code

    return char_to_code


def get_wubi_code(word: str, char_table: Dict[str, str]) -> Optional[str]:
    """Generate Wubi code for a word using standard encoding rules."""
    chars = list(word)
    codes = []

    for c in chars:
        if c in char_table:
            codes.append(char_table[c])
        else:
            return None

    n = len(chars)

    if n == 1:
        return codes[0][:4]
    elif n == 2:
        return codes[0][:2] + codes[1][:2]
    elif n == 3:
        return codes[0][:1] + codes[1][:1] + codes[2][:2]
    else:
        result = codes[0][:1] + codes[1][:1] + codes[2][:1]
        if codes[-1]:
            result += codes[-1][-1]
        return result


def load_pinyin_dict(filepath: str, char_table: Dict[str, str]) -> List[dict]:
    """
    Load entries from py_table.txt with generated wubi codes.
    Format: pinyin word1 word2 ...

    Returns list of entries with pinyin and generated wubi.

    IMPORTANT: Word position in each line determines frequency.
    First word = highest priority (65000), decreasing by 500 per position.
    This ensures common words like 是 rank before rare words like 式 for "shi".
    """
    entries = []
    line_num = 0

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 2:
                continue

            pinyin = parts[0]
            words = parts[1:]

            for word_idx, word in enumerate(words):
                # Position-based frequency: first word = highest priority
                # Word order in source file reflects Chinese usage frequency
                # 是 (position 0) = 65000, 时 (position 1) = 64500, etc.
                base_freq = 65000 - word_idx * 500
                base_freq = max(1000, min(65535, base_freq))  # Floor at 1000

                # Generate wubi code
                wubi = get_wubi_code(word, char_table)

                entries.append({
                    'text': word,
                    'wubi': wubi,
                    'pinyin': pinyin,
                    'baseFrequency': base_freq,
                    'source': SOURCE_PINYIN,
                    'length': len(word)
                })

            line_num += 1

            if line_num % 100000 == 0:
                print(f"  Loaded {line_num} pinyin lines...")

    print(f"  Total: {len(entries)} pinyin entries")
    return entries


def load_extra_pinyin_dict(filepath: str, char_table: Dict[str, str], name: str) -> List[dict]:
    """
    Load entries from extra pinyin dictionaries (cn_en, en, emoji).
    Format: code word1 word2 ...

    All entries get base_frequency = 0 (lowest priority).
    These are supplementary dictionaries.
    """
    entries = []
    line_num = 0

    if not os.path.exists(filepath):
        print(f"  Warning: {name} file not found: {filepath}")
        return entries

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 2:
                continue

            code = parts[0]
            words = parts[1:]

            for word in words:
                # Generate wubi code for Chinese words
                wubi = get_wubi_code(word, char_table) if char_table else None

                entries.append({
                    'text': word,
                    'wubi': wubi,
                    'pinyin': code,
                    'baseFrequency': 1000,  # Base score = 1000 for extra dictionaries
                    'source': SOURCE_EXTRA_PINYIN,
                    'length': len(word)
                })

            line_num += 1

    print(f"  {name}: {len(entries)} entries from {line_num} lines")
    return entries


def merge_dictionaries(
    wubi_entries: List[dict],
    pinyin_entries: List[dict],
    extra_entries: List[dict]
) -> List[dict]:
    """
    Merge wubi, pinyin, and extra pinyin entries into unified dictionary.

    Each word can have multiple entries with different frequencies:
    1. Wubi entry (keyed by text|w|code): Uses code-length frequency (简码优先)
    2. Pinyin entry (keyed by text|p|code): Uses word-position frequency (常用词优先)
    3. Extra pinyin entry (keyed by text|e|code): Base freq = 0

    This ensures correct ranking for both input methods:
    - Wubi input: shorter code entries rank higher
    - Pinyin input: common words like 是 rank before rare words like 式
    - Extra input: only show if no better match exists
    """
    # Key: (text, code) where code is wubi or pinyin
    merged: Dict[str, dict] = {}

    # First add all wubi entries (high priority for wubi input)
    for entry in wubi_entries:
        # Index by wubi code
        wubi_key = f"{entry['text']}|w|{entry['wubi']}"
        if wubi_key not in merged:
            merged[wubi_key] = entry.copy()

    print(f"  After wubi: {len(merged)} entries")

    # Then add pinyin entries
    added = 0
    updated = 0
    for entry in pinyin_entries:
        text = entry['text']
        pinyin = entry['pinyin']
        wubi = entry['wubi']

        # Check if we have this word with same wubi code
        wubi_key = f"{text}|w|{wubi}" if wubi else None
        pinyin_key = f"{text}|p|{pinyin}"

        # If we already have this exact word+wubi from wubi dict, update pinyin field
        # (for reverse lookup), but DON'T skip creating pinyin entry
        if wubi_key and wubi_key in merged:
            if not merged[wubi_key]['pinyin']:
                merged[wubi_key]['pinyin'] = pinyin
                updated += 1
            # NOTE: Removed 'continue' - we still need to create pinyin entry below

        # ALWAYS create pinyin-keyed entry with pinyin frequency
        # This ensures pinyin lookups use position-based frequency
        if pinyin_key not in merged:
            merged[pinyin_key] = entry.copy()
            added += 1

    print(f"  Added {added} pinyin entries, updated {updated} wubi entries with pinyin field")

    # Then add extra pinyin entries (lowest priority)
    extra_added = 0
    for entry in extra_entries:
        text = entry['text']
        pinyin = entry['pinyin']

        # Use 'e' prefix to distinguish extra entries
        extra_key = f"{text}|e|{pinyin}"

        # Only add if this exact text+pinyin combo doesn't exist
        pinyin_key = f"{text}|p|{pinyin}"
        if pinyin_key not in merged and extra_key not in merged:
            merged[extra_key] = entry.copy()
            extra_added += 1

    print(f"  Added {extra_added} extra pinyin entries")
    print(f"  Total merged: {len(merged)} entries")

    # Convert to list and assign IDs
    entries = []
    for idx, entry in enumerate(merged.values()):
        entry['id'] = idx
        entries.append(entry)

    return entries


def build_indexes(entries: List[dict]) -> Tuple[Dict[str, List[int]], Dict[str, List[int]]]:
    """
    Build pinyin and wubi indexes for fast lookup.

    IMPORTANT:
    - Pinyin index: includes all entries with pinyin field (including extra)
    - Wubi index: ONLY includes entries from SOURCE_WUBI (wb_table.txt)

    Returns: (pinyin_index, wubi_index)
    """
    pinyin_index: Dict[str, List[int]] = defaultdict(list)
    wubi_index: Dict[str, List[int]] = defaultdict(list)

    for entry in entries:
        entry_id = entry['id']

        if entry.get('pinyin'):
            pinyin_index[entry['pinyin']].append(entry_id)

        # Only index wubi codes from wubi source entries
        # This ensures wubi search only returns entries from wb_table.txt
        if entry.get('wubi') and entry.get('source') == SOURCE_WUBI:
            wubi_index[entry['wubi']].append(entry_id)

    return dict(pinyin_index), dict(wubi_index)


def save_binary(entries: List[dict], pinyin_index: Dict, wubi_index: Dict, filepath: str):
    """
    Save dictionary in binary format for fast mmap loading.

    Format:
    - Header: magic(4) + version(4) + entry_count(4) + pinyin_index_offset(4) + wubi_index_offset(4)
    - Entries: [id(4) + text_len(2) + text(utf8) + pinyin_len(2) + pinyin(utf8) + wubi_len(2) + wubi(utf8) + freq(2) + source(1) + length(1)]
    - Pinyin Index: [code_len(2) + code(utf8) + count(4) + entry_ids(4*count)]
    - Wubi Index: [code_len(2) + code(utf8) + count(4) + entry_ids(4*count)]
    """
    MAGIC = b'UNIM'
    VERSION = 2

    with open(filepath, 'wb') as f:
        # Write header placeholder
        header_size = 20
        f.write(b'\x00' * header_size)

        # Write entries
        for entry in entries:
            text_bytes = entry['text'].encode('utf-8')
            pinyin_bytes = (entry.get('pinyin') or '').encode('utf-8')
            wubi_bytes = (entry.get('wubi') or '').encode('utf-8')

            f.write(struct.pack('<I', entry['id']))
            f.write(struct.pack('<H', len(text_bytes)))
            f.write(text_bytes)
            f.write(struct.pack('<H', len(pinyin_bytes)))
            f.write(pinyin_bytes)
            f.write(struct.pack('<H', len(wubi_bytes)))
            f.write(wubi_bytes)
            f.write(struct.pack('<H', entry['baseFrequency']))
            f.write(struct.pack('<B', entry['source']))
            f.write(struct.pack('<B', entry['length']))

        # Write pinyin index
        pinyin_index_offset = f.tell()
        f.write(struct.pack('<I', len(pinyin_index)))
        for code, ids in pinyin_index.items():
            code_bytes = code.encode('utf-8')
            f.write(struct.pack('<H', len(code_bytes)))
            f.write(code_bytes)
            f.write(struct.pack('<I', len(ids)))
            for entry_id in ids:
                f.write(struct.pack('<I', entry_id))

        # Write wubi index
        wubi_index_offset = f.tell()
        f.write(struct.pack('<I', len(wubi_index)))
        for code, ids in wubi_index.items():
            code_bytes = code.encode('utf-8')
            f.write(struct.pack('<H', len(code_bytes)))
            f.write(code_bytes)
            f.write(struct.pack('<I', len(ids)))
            for entry_id in ids:
                f.write(struct.pack('<I', entry_id))

        # Go back and write header
        f.seek(0)
        f.write(MAGIC)
        f.write(struct.pack('<I', VERSION))
        f.write(struct.pack('<I', len(entries)))
        f.write(struct.pack('<I', pinyin_index_offset))
        f.write(struct.pack('<I', wubi_index_offset))

    print(f"  Binary size: {os.path.getsize(filepath) / 1024 / 1024:.1f} MB")


def save_json(entries: List[dict], filepath: str):
    """Save entries as JSON for debugging."""
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(entries, f, ensure_ascii=False)
    print(f"  JSON size: {os.path.getsize(filepath) / 1024 / 1024:.1f} MB")


def save_metadata(entries: List[dict], output_dir: str):
    """Save dictionary metadata."""
    wubi_count = sum(1 for e in entries if e['source'] == SOURCE_WUBI)
    pinyin_count = sum(1 for e in entries if e['source'] == SOURCE_PINYIN)
    extra_count = sum(1 for e in entries if e['source'] == SOURCE_EXTRA_PINYIN)

    metadata = {
        'version': '2.1.0',
        'created_at': datetime.now().isoformat(),
        'entry_count': len(entries),
        'wubi_entries': wubi_count,
        'pinyin_entries': pinyin_count,
        'extra_pinyin_entries': extra_count,
        'format': 'sqlite'
    }

    filepath = os.path.join(output_dir, 'metadata.json')
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2)


def backup_user_data(db_path: str) -> Tuple[list, list, list]:
    """
    Backup user_learning and user_favorites data from existing database.
    Returns (user_learning_rows, user_favorites_rows)
    """
    if not os.path.exists(db_path):
        return [], [], []

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    user_learning = []
    user_favorites = []

    try:
        # Backup user_learning
        cursor.execute("SELECT entry_id, access_count, last_access_timestamp, total_score FROM user_learning")
        user_learning = cursor.fetchall()
        print(f"  Backed up {len(user_learning)} user_learning records")
    except sqlite3.OperationalError:
        print("  No user_learning table found (new database)")

    try:
        # Backup user_favorites
        cursor.execute("SELECT text, wubi_code, pinyin_code, added_timestamp FROM user_favorites")
        user_favorites = cursor.fetchall()
        print(f"  Backed up {len(user_favorites)} user_favorites records")
    except sqlite3.OperationalError:
        print("  No user_favorites table found (new database)")

    try:
        # Also backup filter_user_freq if exists
        cursor.execute("SELECT filter_type, code, word, frequency, last_used FROM filter_user_freq")
        filter_freq = cursor.fetchall()
        if filter_freq:
            print(f"  Backed up {len(filter_freq)} filter_user_freq records")
    except sqlite3.OperationalError:
        filter_freq = []

    conn.close()
    return user_learning, user_favorites, filter_freq


def restore_user_data(db_path: str, user_learning: list, user_favorites: list, filter_freq: list):
    """
    Restore user_learning and user_favorites data to new database.
    """
    if not user_learning and not user_favorites and not filter_freq:
        print("  No user data to restore")
        return

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Restore user_learning
    if user_learning:
        cursor.executemany(
            "INSERT OR REPLACE INTO user_learning (entry_id, access_count, last_access_timestamp, total_score) VALUES (?, ?, ?, ?)",
            user_learning
        )
        print(f"  Restored {len(user_learning)} user_learning records")

    # Restore user_favorites
    if user_favorites:
        cursor.executemany(
            "INSERT OR REPLACE INTO user_favorites (text, wubi_code, pinyin_code, added_timestamp) VALUES (?, ?, ?, ?)",
            user_favorites
        )
        print(f"  Restored {len(user_favorites)} user_favorites records")

    # Restore filter_user_freq
    if filter_freq:
        cursor.executemany(
            "INSERT OR REPLACE INTO filter_user_freq (filter_type, code, word, frequency, last_used) VALUES (?, ?, ?, ?, ?)",
            filter_freq
        )
        print(f"  Restored {len(filter_freq)} filter_user_freq records")

    conn.commit()
    conn.close()


def install_to_marmotim(output_dir: str):
    """
    Install dictionary files to MarmotIM application directory.
    Copies dictionary.db to ~/Library/Application Support/MarmotIM/
    IMPORTANT: Preserves user_learning and user_favorites data!
    """
    # Determine MarmotIM directory (main directory, not dict/ subdirectory)
    home = Path.home()
    marmotim_dict_dir = home / "Library" / "Application Support" / "MarmotIM"

    # Create directory if it doesn't exist
    marmotim_dict_dir.mkdir(parents=True, exist_ok=True)

    # Handle dictionary.db specially to preserve user data
    src_db = os.path.join(output_dir, 'dictionary.db')
    dst_db = marmotim_dict_dir / 'dictionary.db'

    if os.path.exists(src_db):
        # Step 1: Backup user data from existing database
        print("  Preserving user data...")
        user_learning, user_favorites, filter_freq = backup_user_data(str(dst_db))

        # Step 2: Backup existing file
        if dst_db.exists():
            backup = dst_db.with_suffix('.db.bak')
            shutil.copy2(dst_db, backup)
            print(f"  Backed up dictionary.db to dictionary.db.bak")

        # Step 3: Remove old WAL files (they are incompatible with new database)
        wal_file = dst_db.with_suffix('.db-wal')
        shm_file = dst_db.with_suffix('.db-shm')
        if wal_file.exists():
            os.remove(wal_file)
            print(f"  Removed old WAL file")
        if shm_file.exists():
            os.remove(shm_file)
            print(f"  Removed old SHM file")

        # Step 4: Copy new database
        shutil.copy2(src_db, dst_db)
        print(f"  Installed dictionary.db to {marmotim_dict_dir}")

        # Step 5: Restore user data to new database
        print("  Restoring user data...")
        restore_user_data(str(dst_db), user_learning, user_favorites, filter_freq)
    else:
        print(f"  Warning: dictionary.db not found in output directory")

    # Install other files (metadata.json)
    for filename in ['metadata.json']:
        src = os.path.join(output_dir, filename)
        dst = marmotim_dict_dir / filename

        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f"  Installed {filename}")

    print(f"  Installation complete: {marmotim_dict_dir}")


def save_sqlite(entries: List[dict], pinyin_index: Dict, wubi_index: Dict, filepath: str):
    """
    Save dictionary in SQLite format for the new Trie-based architecture.

    Tables:
    - entries: Main dictionary entries
    - pinyin_index: Pinyin code to entry ID mapping
    - wubi_index: Wubi code to entry ID mapping
    - user_learning: User frecency data (empty, to be populated at runtime)
    """
    # Remove existing file
    if os.path.exists(filepath):
        os.remove(filepath)

    conn = sqlite3.connect(filepath)
    cursor = conn.cursor()

    # Create tables
    cursor.executescript('''
        -- Main entries table
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            pinyin TEXT,
            wubi TEXT,
            base_frequency INTEGER NOT NULL DEFAULT 0,
            source INTEGER NOT NULL DEFAULT 1,
            length INTEGER NOT NULL,
            created_at INTEGER DEFAULT (strftime('%s', 'now'))
        );

        -- Pinyin index table
        CREATE TABLE pinyin_index (
            code TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            PRIMARY KEY (code, entry_id),
            FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
        );

        -- Wubi index table
        CREATE TABLE wubi_index (
            code TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            PRIMARY KEY (code, entry_id),
            FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
        );

        -- User learning table (empty - populated at runtime)
        CREATE TABLE user_learning (
            entry_id INTEGER PRIMARY KEY,
            access_count INTEGER NOT NULL DEFAULT 0,
            last_access_timestamp INTEGER NOT NULL DEFAULT 0,
            total_score REAL NOT NULL DEFAULT 0,
            FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
        );

        -- User favorites table (tracks entries added via control+=)
        CREATE TABLE user_favorites (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            wubi_code TEXT,
            pinyin_code TEXT,
            added_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            UNIQUE(text, wubi_code, pinyin_code)
        );

        -- Schema version table
        CREATE TABLE schema_version (
            version INTEGER PRIMARY KEY
        );

        -- Filter mode tables
        CREATE TABLE emoji_index (
            id INTEGER PRIMARY KEY,
            code TEXT NOT NULL,
            code_type TEXT NOT NULL,
            emoji TEXT NOT NULL,
            frequency INTEGER DEFAULT 0,
            UNIQUE(code, emoji)
        );

        CREATE TABLE fuzzy_pinyin (
            id INTEGER PRIMARY KEY,
            fuzzy_code TEXT NOT NULL,
            original_code TEXT NOT NULL,
            word TEXT NOT NULL,
            fuzzy_type TEXT NOT NULL,
            UNIQUE(fuzzy_code, original_code, word)
        );

        CREATE TABLE symbol_index (
            id INTEGER PRIMARY KEY,
            code TEXT NOT NULL,
            symbol TEXT NOT NULL,
            category TEXT,
            description TEXT
        );

        CREATE TABLE filter_user_freq (
            filter_type TEXT NOT NULL,
            code TEXT NOT NULL,
            word TEXT NOT NULL,
            frequency INTEGER DEFAULT 1,
            last_used REAL,
            PRIMARY KEY (filter_type, code, word)
        );

        -- Create indexes for fast prefix queries
        CREATE INDEX idx_pinyin_prefix ON pinyin_index(code);
        CREATE INDEX idx_wubi_prefix ON wubi_index(code);
        CREATE INDEX idx_user_learning_score ON user_learning(total_score DESC);
        CREATE INDEX idx_entries_source ON entries(source);
        CREATE INDEX idx_user_favorites_text ON user_favorites(text);
        CREATE INDEX idx_emoji_code ON emoji_index(code);
        CREATE INDEX idx_fuzzy_code ON fuzzy_pinyin(fuzzy_code);
        CREATE INDEX idx_symbol_code ON symbol_index(code);
        CREATE INDEX idx_filter_freq ON filter_user_freq(filter_type, code);
    ''')

    # Set schema version
    cursor.execute("INSERT INTO schema_version (version) VALUES (1)")
    conn.commit()

    # Insert entries in a single transaction for performance
    print("    Inserting entries...")
    conn.execute("BEGIN TRANSACTION")

    entry_data = [
        (
            e['id'],
            e['text'],
            e.get('pinyin') or '',
            e.get('wubi'),
            e['baseFrequency'],
            e['source'],
            e['length']
        )
        for e in entries
    ]

    cursor.executemany(
        "INSERT INTO entries (id, text, pinyin, wubi, base_frequency, source, length) VALUES (?, ?, ?, ?, ?, ?, ?)",
        entry_data
    )
    print(f"    Inserted {len(entries)} entries")

    # Insert pinyin indexes
    print("    Inserting pinyin indexes...")
    pinyin_data = []
    for code, ids in pinyin_index.items():
        for entry_id in ids:
            pinyin_data.append((code, entry_id))

    cursor.executemany(
        "INSERT INTO pinyin_index (code, entry_id) VALUES (?, ?)",
        pinyin_data
    )
    print(f"    Inserted {len(pinyin_data)} pinyin index entries")

    # Insert wubi indexes
    print("    Inserting wubi indexes...")
    wubi_data = []
    for code, ids in wubi_index.items():
        for entry_id in ids:
            wubi_data.append((code, entry_id))

    cursor.executemany(
        "INSERT INTO wubi_index (code, entry_id) VALUES (?, ?)",
        wubi_data
    )
    print(f"    Inserted {len(wubi_data)} wubi index entries")

    conn.commit()

    # Optimize database
    print("    Optimizing database...")
    cursor.execute("ANALYZE")
    cursor.execute("VACUUM")

    # Configure database for durability
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=FULL")

    conn.close()

    file_size = os.path.getsize(filepath)
    print(f"  SQLite size: {file_size / 1024 / 1024:.1f} MB")


def build_emoji_index(cursor, emoji_paths: list, vocab_dir: Optional[str] = None):
    """Build emoji index from multiple emoji table files."""
    print(f"Building emoji index from {len(emoji_paths)} files...")

    cursor.execute("DELETE FROM emoji_index")

    entries = []  # Collect entries for txt export
    count = 0

    for emoji_path in emoji_paths:
        if not os.path.exists(emoji_path):
            print(f"  Warning: {emoji_path} not found, skipping")
            continue

        print(f"  Processing {emoji_path}...")
        with open(emoji_path, 'r', encoding='utf-8') as f:
            for line in f:
                # Skip comments
                if line.startswith('#'):
                    continue
                parts = line.strip().split()
                if len(parts) < 2:
                    continue

                code = parts[0]
                emojis = parts[1:]

                for emoji in emojis:
                    cursor.execute(
                        "INSERT OR IGNORE INTO emoji_index (code, code_type, emoji, frequency) VALUES (?, ?, ?, ?)",
                        (code, 'code', emoji, 0)
                    )
                    entries.append((code, 'code', emoji))
                    count += 1

    print(f"  Added {count} emoji entries total")

    # Save to txt file in vocab directory
    if vocab_dir:
        save_emoji_index_txt(entries, vocab_dir)


def save_emoji_index_txt(entries: list, vocab_dir: str):
    """Save emoji index as txt file to vocab directory"""
    output_path = os.path.join(vocab_dir, 'emoji_index.txt')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write("# Emoji Index - Generated by build_dictionary.py\n")
        f.write("# Format: code code_type emoji\n")
        for code, code_type, emoji in entries:
            f.write(f"{code}\t{code_type}\t{emoji}\n")
    print(f"  Saved emoji index to {output_path}")


FUZZY_RULES = {
    'initial': [
        ('zh', 'z'), ('ch', 'c'), ('sh', 's'),
        ('n', 'l'), ('r', 'l'), ('f', 'h')
    ],
    'final': [
        ('ang', 'an'), ('eng', 'en'), ('ing', 'in'),
        ('iang', 'ian'), ('uang', 'uan')
    ]
}


def generate_fuzzy_variants(pinyin: str, word: str):
    """Generate fuzzy variants for a pinyin"""
    variants = []
    for rule_type, rules in FUZZY_RULES.items():
        for a, b in rules:
            if a in pinyin:
                fuzzy = pinyin.replace(a, b, 1)
                variants.append((fuzzy, pinyin, word, rule_type))
            if b in pinyin:
                fuzzy = pinyin.replace(b, a, 1)
                variants.append((fuzzy, pinyin, word, rule_type))
    return variants


def build_fuzzy_pinyin_index(cursor, pinyin_path: str, vocab_dir: Optional[str] = None):
    """Build fuzzy pinyin index"""
    print(f"Building fuzzy pinyin index from {pinyin_path}...")

    cursor.execute("DELETE FROM fuzzy_pinyin")

    entries = []  # Collect entries for txt export
    count = 0
    with open(pinyin_path, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 2:
                continue

            pinyin = parts[0]
            words = parts[1:]

            for word in words[:3]:  # Limit to top 3 words per pinyin
                for fuzzy_code, original, w, fuzzy_type in generate_fuzzy_variants(pinyin, word):
                    cursor.execute(
                        "INSERT OR IGNORE INTO fuzzy_pinyin (fuzzy_code, original_code, word, fuzzy_type) VALUES (?, ?, ?, ?)",
                        (fuzzy_code, original, w, fuzzy_type)
                    )
                    entries.append((fuzzy_code, original, w, fuzzy_type))
                    count += 1

    print(f"  Added {count} fuzzy pinyin entries")

    # Save to txt file in vocab directory
    if vocab_dir:
        save_fuzzy_pinyin_txt(entries, vocab_dir)


def save_fuzzy_pinyin_txt(entries: list, vocab_dir: str):
    """Save fuzzy pinyin index as txt file to vocab directory"""
    output_path = os.path.join(vocab_dir, 'fuzzy_pinyin.txt')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write("# Fuzzy Pinyin Index - Generated by build_dictionary.py\n")
        f.write("# Format: fuzzy_code original_code word fuzzy_type\n")
        for fuzzy_code, original, word, fuzzy_type in entries:
            f.write(f"{fuzzy_code}\t{original}\t{word}\t{fuzzy_type}\n")
    print(f"  Saved fuzzy pinyin index to {output_path}")


def build_symbol_index(cursor, symbols_path: str, vocab_dir: Optional[str] = None):
    """Build symbol index from symbols.yaml"""
    if not YAML_AVAILABLE:
        print("Warning: PyYAML not installed. Run: pip install pyyaml")
        return

    print(f"Building symbol index from {symbols_path}...")

    cursor.execute("DELETE FROM symbol_index")

    with open(symbols_path, 'r', encoding='utf-8') as f:
        content = yaml.safe_load(f)  # type: ignore[union-attr]

    entries = []  # Collect entries for txt export
    count = 0
    symbols = content.get('punctuator', {}).get('symbols', {})

    for code, symbol_list in symbols.items():
        if not code.startswith('/'):
            continue

        category = code[1:]  # Remove leading /

        if isinstance(symbol_list, list):
            for symbol in symbol_list:
                cursor.execute(
                    "INSERT INTO symbol_index (code, symbol, category, description) VALUES (?, ?, ?, ?)",
                    (category, str(symbol), category, None)
                )
                entries.append((category, str(symbol), category))
                count += 1

    print(f"  Added {count} symbol entries")

    # Save to txt file in vocab directory
    if vocab_dir:
        save_symbol_index_txt(entries, vocab_dir)


def save_symbol_index_txt(entries: list, vocab_dir: str):
    """Save symbol index as txt file to vocab directory"""
    output_path = os.path.join(vocab_dir, 'symbol_index.txt')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write("# Symbol Index - Generated by build_dictionary.py\n")
        f.write("# Format: code symbol category\n")
        for code, symbol, category in entries:
            f.write(f"{code}\t{symbol}\t{category}\n")
    print(f"  Saved symbol index to {output_path}")


def load_corpus_frequencies(filepath: str) -> Dict[str, float]:
    """
    Load word frequency data from a corpus file.
    Expected format: word<tab>frequency per line

    Supports:
    - BCC corpus format (word\tfrequency)
    - SUBTLEX-CH format
    - Generic TSV format
    """
    frequencies = {}

    if not os.path.exists(filepath):
        print(f"  Warning: Corpus file not found: {filepath}")
        return frequencies

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 2:
                word = parts[0]
                try:
                    freq = float(parts[1])
                    frequencies[word] = freq
                except ValueError:
                    continue

    print(f"  Loaded {len(frequencies)} corpus frequencies")
    return frequencies


def normalize_frequency(raw_freq: float, max_freq: float) -> int:
    """
    Convert raw corpus frequency to 0-65535 range using log scale.

    Log scale ensures common words (的、是、在) don't completely dominate
    while still maintaining relative ordering.
    """
    if raw_freq <= 0:
        return 1000  # Default for unknown words

    # Log scale: log(freq + 1) / log(max_freq + 1) * 65000
    log_freq = math.log(raw_freq + 1)
    log_max = math.log(max_freq + 1)
    normalized = int((log_freq / log_max) * 65000)

    return max(1, min(65535, normalized))


def apply_corpus_frequencies(entries: List[dict], corpus_freq: Dict[str, float]) -> List[dict]:
    """
    Apply corpus-based frequencies to pinyin entries.
    Wubi entries keep their original frequencies (code-length based).
    """
    if not corpus_freq:
        return entries

    max_freq = max(corpus_freq.values()) if corpus_freq else 1
    updated = 0

    for entry in entries:
        # Only update pinyin entries
        if entry['source'] == SOURCE_PINYIN:
            text = entry['text']
            if text in corpus_freq:
                entry['baseFrequency'] = normalize_frequency(corpus_freq[text], max_freq)
                updated += 1

    print(f"  Updated {updated} entries with corpus frequencies")
    return entries


def main():
    # Get project root directory (parent of tools/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    vocab_dir = os.path.join(project_root, 'vocab')
    dict_dir = os.path.join(project_root, 'dict')

    parser = argparse.ArgumentParser(
        description='Build MarmotIM dictionary. Can be run without arguments to build with defaults.')

    # Core paths with sensible defaults
    parser.add_argument('--pinyin', default=os.path.join(vocab_dir, 'py_table.txt'),
                        help='Path to py_table.txt (default: vocab/py_table.txt)')
    parser.add_argument('--wubi', default=os.path.join(vocab_dir, 'wb_table.txt'),
                        help='Path to wb_table.txt (default: vocab/wb_table.txt)')
    parser.add_argument('--output', default=dict_dir,
                        help='Output directory (default: dict/)')
    parser.add_argument('--corpus', help='Path to corpus frequency file (optional)')
    parser.add_argument('--limit', type=int, help='Limit pinyin entries (for testing)')
    parser.add_argument('--skip-binary', action='store_true', default=True,
                        help='Skip binary output (default: True, SQLite only)')
    parser.add_argument('--skip-json', action='store_true', default=True,
                        help='Skip JSON output (default: True)')

    # Extra pinyin dictionaries
    parser.add_argument('--cn-en', help='Path to cn_en_table.txt (Chinese-English mixed)')
    parser.add_argument('--en', help='Path to en_table.txt (English vocabulary)')
    parser.add_argument('--emoji', help='Path to emoji_table.txt (Emoji vocabulary)')
    parser.add_argument('--extra-pinyin-dir', default=vocab_dir,
                        help='Directory containing extra pinyin tables (default: vocab/)')
    parser.add_argument('--install', action='store_true', default=True,
                        help='Install dictionary to MarmotIM application directory (default: True)')
    parser.add_argument('--no-install', action='store_true',
                        help='Do not install dictionary after building')

    # Filter dictionary build options - all enabled by default
    parser.add_argument('--build-emoji', action='store_true', default=True,
                        help='Build emoji index (default: True)')
    parser.add_argument('--build-fuzzy', action='store_true', default=True,
                        help='Build fuzzy pinyin index (default: True)')
    parser.add_argument('--build-symbol', action='store_true', default=True,
                        help='Build symbol index (default: True)')

    args = parser.parse_args()

    # Handle --no-install flag
    if args.no_install:
        args.install = False

    os.makedirs(args.output, exist_ok=True)

    print("Step 1: Loading Wubi dictionary (HIGH PRIORITY)...")
    wubi_entries = load_wubi_dict(args.wubi)

    print("\nStep 2: Loading Wubi character table...")
    char_table = load_wubi_char_table(args.wubi)
    print(f"  {len(char_table)} character mappings")

    print("\nStep 3: Loading Pinyin dictionary (LOWER PRIORITY)...")
    pinyin_entries = load_pinyin_dict(args.pinyin, char_table)

    if args.limit:
        print(f"  Limiting to {args.limit} pinyin entries")
        pinyin_entries = pinyin_entries[:args.limit]

    print("\nStep 4: Loading Extra Pinyin dictionaries (LOWEST PRIORITY, base_freq=1000)...")
    extra_entries = []

    # Determine paths for extra dictionaries
    cn_en_path = args.cn_en
    en_path = args.en
    emoji_path = args.emoji

    if args.extra_pinyin_dir:
        base_dir = args.extra_pinyin_dir
        if not cn_en_path:
            cn_en_path = os.path.join(base_dir, 'cn_en_table.txt')
        if not en_path:
            en_path = os.path.join(base_dir, 'en_table.txt')
        if not emoji_path:
            emoji_path = os.path.join(base_dir, 'emoji_table.txt')

    # Load each extra dictionary
    if cn_en_path:
        extra_entries.extend(load_extra_pinyin_dict(cn_en_path, char_table, 'cn_en'))
    if en_path:
        extra_entries.extend(load_extra_pinyin_dict(en_path, char_table, 'en'))
    if emoji_path:
        extra_entries.extend(load_extra_pinyin_dict(emoji_path, char_table, 'emoji'))

    print(f"  Total extra pinyin entries: {len(extra_entries)}")

    print("\nStep 5: Merging dictionaries...")
    entries = merge_dictionaries(wubi_entries, pinyin_entries, extra_entries)

    # Apply corpus frequencies if provided
    if args.corpus:
        print("\nStep 5b: Loading corpus frequencies...")
        corpus_freq = load_corpus_frequencies(args.corpus)
        if corpus_freq:
            print("  Applying corpus frequencies to pinyin entries...")
            entries = apply_corpus_frequencies(entries, corpus_freq)

    print("\nStep 6: Building indexes...")
    pinyin_index, wubi_index = build_indexes(entries)
    print(f"  Pinyin codes: {len(pinyin_index)}")
    print(f"  Wubi codes: {len(wubi_index)}")

    # Save SQLite (primary format for new architecture)
    print("\nStep 7: Saving SQLite format (primary)...")
    save_sqlite(entries, pinyin_index, wubi_index, os.path.join(args.output, 'dictionary.db'))

    # Build filter dictionaries if requested
    if args.build_emoji or args.build_fuzzy or args.build_symbol:
        print("\nStep 7b: Building filter dictionaries...")
        db_path = os.path.join(args.output, 'dictionary.db')
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        # vocab_dir is where source files are located and where we save generated txt files
        vocab_dir = os.path.dirname(args.pinyin)

        if args.build_emoji:
            emoji_files = [
                os.path.join(vocab_dir, 'emoji_table.txt'),
                os.path.join(vocab_dir, 'emoji_en_table.txt')
            ]
            build_emoji_index(cursor, emoji_files, vocab_dir)

        if args.build_fuzzy:
            build_fuzzy_pinyin_index(cursor, args.pinyin, vocab_dir)

        if args.build_symbol:
            symbol_path = os.path.join(vocab_dir, 'symbols.yaml')
            if os.path.exists(symbol_path):
                build_symbol_index(cursor, symbol_path, vocab_dir)
            else:
                print(f"Warning: symbols.yaml not found at {symbol_path}")

        conn.commit()
        conn.close()

    # Save binary format (legacy, optional)
    if not args.skip_binary:
        print("\nStep 8: Saving binary format (legacy)...")
        save_binary(entries, pinyin_index, wubi_index, os.path.join(args.output, 'dictionary.bin'))
    else:
        print("\nStep 8: Skipping binary format...")

    # Save JSON backup (optional)
    if not args.skip_json:
        print("\nStep 9: Saving JSON backup...")
        save_json(entries, os.path.join(args.output, 'entries.json'))
    else:
        print("\nStep 9: Skipping JSON backup...")

    print("\nStep 10: Saving metadata...")
    save_metadata(entries, args.output)

    # Statistics
    wubi_count = sum(1 for e in entries if e['source'] == SOURCE_WUBI)
    pinyin_count = sum(1 for e in entries if e['source'] == SOURCE_PINYIN)
    extra_count = sum(1 for e in entries if e['source'] == SOURCE_EXTRA_PINYIN)

    print(f"\n{'='*50}")
    print(f"STATISTICS:")
    print(f"  Total entries: {len(entries):,}")
    print(f"  Wubi entries (high priority): {wubi_count:,}")
    print(f"  Pinyin entries: {pinyin_count:,}")
    print(f"  Extra pinyin entries (cn_en, en, emoji): {extra_count:,}")
    print(f"  Pinyin index codes: {len(pinyin_index):,}")
    print(f"  Wubi index codes: {len(wubi_index):,}")
    print(f"{'='*50}")

    # Install to MarmotIM application directory
    if args.install:
        print("\nStep 11: Installing to MarmotIM...")
        install_to_marmotim(args.output)

    print("\nDone!")


if __name__ == '__main__':
    main()
