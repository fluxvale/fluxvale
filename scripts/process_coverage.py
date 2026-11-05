#!/usr/bin/env python3
"""
Process excoveralls.json to add marker-ignored line markers for Codecov.

This ensures lines between coveralls-ignore-start/stop comments are marked
appropriately in the JSON so Codecov sees the same coverage as the Elixir gate.
"""

import json
import sys
import os
import re


def extract_coveralls_ignore_blocks(filepath):
    """
    Extract line numbers for coveralls-ignore markers in a source file.

    Returns a list of (start_line, end_line) tuples for blocks that are ignored.
    """
    ignore_blocks = []
    in_inline_ignore = False
    next_line_ignore = False

    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()

            for i, line in enumerate(lines, 1):
                stripped = line.strip()

                # Handle inline ignore next line
                if 'coveralls-ignore-next-line' in stripped:
                    if i < len(lines):
                        next_line_ignore = True
                    continue

                # Handle block ignore start
                if stripped == '# coveralls-ignore-start':
                    in_inline_ignore = False  # Reset state
                    in_block_ignore = True
                    block_start = i
                    continue

                # Handle block ignore stop
                if stripped == '# coveralls-ignore-stop' and in_block_ignore:
                    ignore_blocks.append((block_start, i))
                    in_block_ignore = False
                    block_start = None
                    continue

                # Check if we're inside a block and should ignore this line
                if in_block_ignore:
                    ignore_blocks.append((block_start, i))
                    continue

    except Exception as e:
        # If reading fails, continue without processing this file
        print(f"Warning: Could not read {filepath}: {e}", file=sys.stderr)

    return ignore_blocks


def process_coverage_json(coverage_file, repo_root):
    """
    Process the coverage JSON file to mark marker-ignored lines.

    Args:
        coverage_file: Path to the excoveralls.json file
        repo_root: Repository root directory for resolving file paths
    """
    with open(coverage_file, 'r') as f:
        data = json.load(f)

    updated = False

    # Handle both possible JSON formats
    if 'source_files' in data:
        source_files = data['source_files']

        for sf in source_files:
            filepath = sf.get('name')
            if not filepath:
                continue

            # Convert relative path to absolute path
            rel_path = filepath.lstrip('/')
            abs_path = os.path.join(repo_root, rel_path)

            if not os.path.exists(abs_path):
                continue

            # Extract ignore blocks from source
            ignore_blocks = extract_coveralls_ignore_blocks(abs_path)

            # Get existing coverage array (1-indexed, but Python is 0-indexed)
            coverage = sf.get('coverage', [])

            if ignore_blocks and coverage:
                # Convert to 0-indexed list for easier processing
                new_coverage = coverage.copy()

                for start, end in ignore_blocks:
                    # Convert to 0-indexed
                    start_idx = start - 1
                    end_idx = end - 1

                    # Mark lines in this interval as None (ignored)
                    for line in range(start_idx, min(end_idx + 1, len(new_coverage))):
                        if new_coverage[line] is not None:
                            new_coverage[line] = None
                            updated = True

                # Update the coverage in source_files
                sf['coverage'] = new_coverage

    elif 'coverage' in data:
        coverage_map = data['coverage']

        for filepath, line_coverage in coverage_map.items():
            abs_path = os.path.join(repo_root, filepath.lstrip('/'))

            if not os.path.exists(abs_path):
                continue

            ignore_blocks = extract_coveralls_ignore_blocks(abs_path)

            if ignore_blocks and line_coverage:
                # Convert to 0-indexed list
                new_coverage = list(line_coverage) if not isinstance(line_coverage, list) else line_coverage.copy()

                for start, end in ignore_blocks:
                    start_idx = start - 1
                    end_idx = end - 1

                    for line in range(start_idx, min(end_idx + 1, len(new_coverage))):
                        if new_coverage[line] is not None:
                            new_coverage[line] = None
                            updated = True

                # Update coverage map value
                if isinstance(line_coverage, dict):
                    # Convert back to dict for original format
                    line_coverage.update({i + 1: val for i, val in enumerate(new_coverage)})
                else:
                    data['coverage'][filepath] = new_coverage

    # Write the processed JSON back
    with open(coverage_file, 'w') as f:
        json.dump(data, f, indent=2)

    return updated


def main():
    if len(sys.argv) < 2:
        print("Usage: process_coverage.py <coverage_json> [repo_root]")
        print("If repo_root is not provided, uses current directory")
        sys.exit(1)

    coverage_file = sys.argv[1]
    repo_root = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.getcwd()

    if not os.path.isabs(coverage_file):
        coverage_file = os.path.join(repo_root, coverage_file)

    updated = process_coverage_json(coverage_file, repo_root)

    if updated:
        print(f"Updated: {coverage_file} - marked ignored lines as no coverage")
    else:
        print(f"No marker-ignored blocks found in {coverage_file}")


if __name__ == '__main__':
    main()
