import os

wb_path = 'vocab/wb_table.txt'
jianma_path = 'vocab/jianma.txt'

entries = {}

if os.path.exists(wb_path):
    with open(wb_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) >= 2:
                code = parts[0]
                # Filter for Level 1 (1 char) and Level 2 (2 chars)
                if len(code) <= 2:
                    word = parts[1] # First word is the default candidate
                    if code not in entries:
                        entries[code] = word

    # Sort by code length then code
    sorted_codes = sorted(entries.keys(), key=lambda x: (len(x), x))

    with open(jianma_path, 'w') as f:
        f.write("# Standard Jianma Table (Level 1 & 2)\n")
        f.write("# These entries are locked with MAX priority.\n")
        for code in sorted_codes:
            f.write(f"{code} {entries[code]}\n")

    print(f"Generated {len(entries)} jianma entries from {wb_path}.")
else:
    print(f"Error: {wb_path} not found.")
