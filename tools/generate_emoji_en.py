#!/usr/bin/env python3
"""
Generate emoji English codes from Unicode CLDR data.
Reads emojis from emoji_table.txt and outputs emoji_en_table.txt with Unicode short names.
"""

import unicodedata
import re
import sys
from pathlib import Path
from typing import Optional


def get_emoji_name(emoji: str) -> Optional[str]:
    """Get Unicode name for an emoji, convert to snake_case code."""
    try:
        # Handle multi-codepoint emojis (ZWJ sequences, skin tones, etc.)
        # Try to get name for the base character
        name = unicodedata.name(emoji[0], None)
        if name:
            # Convert to lowercase snake_case
            name = name.lower().replace(' ', '_').replace('-', '_')
            # Remove common prefixes
            name = re.sub(r'^(emoji_modifier_fitzpatrick_type_|variation_selector_)', '', name)
            return name
    except (TypeError, ValueError):
        pass
    return None


def extract_unique_emojis(emoji_table_path: Path) -> set:
    """Extract all unique emojis from emoji_table.txt"""
    emojis = set()
    with open(emoji_table_path, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 2:
                for emoji in parts[1:]:
                    # Skip non-emoji entries (currency symbols, etc.)
                    if len(emoji) <= 10:  # Reasonable emoji length
                        emojis.add(emoji)
    return emojis


def generate_emoji_en_table(vocab_dir: Path):
    """Generate emoji_en_table.txt with English codes."""
    emoji_table_path = vocab_dir / 'emoji_table.txt'
    output_path = vocab_dir / 'emoji_en_table.txt'

    if not emoji_table_path.exists():
        print(f"Error: {emoji_table_path} not found")
        sys.exit(1)

    # Extract unique emojis
    emojis = extract_unique_emojis(emoji_table_path)
    print(f"Found {len(emojis)} unique emojis")

    # Generate English codes
    emoji_codes = {}  # code -> [emojis]
    unmapped = []

    for emoji in emojis:
        name = get_emoji_name(emoji)
        if name:
            if name not in emoji_codes:
                emoji_codes[name] = []
            emoji_codes[name].append(emoji)
        else:
            unmapped.append(emoji)

    print(f"Mapped {len(emoji_codes)} unique codes")
    print(f"Unmapped: {len(unmapped)} emojis")

    # Write output
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write("# Emoji English Codes - Generated from Unicode names\n")
        f.write("# Format: code emoji [emoji ...]\n")
        for code in sorted(emoji_codes.keys()):
            emojis_str = ' '.join(emoji_codes[code])
            f.write(f"{code} {emojis_str}\n")

    print(f"Wrote {output_path}")


if __name__ == '__main__':
    # Default to vocab directory relative to script
    script_dir = Path(__file__).parent
    vocab_dir = script_dir.parent / 'vocab'

    if len(sys.argv) > 1:
        vocab_dir = Path(sys.argv[1])

    generate_emoji_en_table(vocab_dir)
