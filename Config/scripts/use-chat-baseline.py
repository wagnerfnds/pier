#!/usr/bin/env python3
"""Use the released chat implementation for an A/B run, keeping the same test instrumentation.

GitHub Actions may replace ConversationView.swift in its disposable checkout. Local inspection must use --output
to write a scratch file. App identity, mock fixtures, test code and all other sources stay as they are.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys


BASELINE_REF = "pier-mac-v1.1"
SOURCE_PATH = Path("App/Features/Session/ConversationView.swift")
SCROLL_ANCHOR = "            .defaultScrollAnchor(.bottom)\n"
SCROLL_ID = '            .accessibilityIdentifier("conversation-scroll")\n'
DRAFT_OBSERVER = "            .background { LegacyDraftFollow(vm: vm) { followLegacy(proxy) } }\n"
PROBE = """            .background {
                #if DEBUG
                ChatHistoryProbe()
                #endif
            }
"""


def instrument(source: str) -> str:
    """Fail if the fixed release no longer has the expected insertion points; never patch a partial match."""
    for marker in (SCROLL_ANCHOR, DRAFT_OBSERVER):
        if source.count(marker) != 1:
            raise ValueError(f"Expected exactly one baseline insertion point: {marker.strip()}")
    for addition in (SCROLL_ID, PROBE):
        if addition in source:
            raise ValueError("The baseline already contains test instrumentation")

    result = source.replace(SCROLL_ANCHOR, SCROLL_ID + SCROLL_ANCHOR, 1)
    result = result.replace(DRAFT_OBSERVER, DRAFT_OBSERVER + PROBE, 1)
    if result.replace(SCROLL_ID, "", 1).replace(PROBE, "", 1) != source:
        raise ValueError("Baseline instrumentation unexpectedly changed the original source")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write the instrumented baseline to a scratch file instead of the app source")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    destination = args.output.resolve() if args.output else root / SOURCE_PATH
    if destination == root / SOURCE_PATH and os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("Replacing the app source is for GitHub Actions only; use --output for local inspection")

    try:
        baseline = subprocess.run(
            ["git", "-C", str(root), "show", f"{BASELINE_REF}:{SOURCE_PATH.as_posix()}"],
            check=True, capture_output=True,
        ).stdout
        result = instrument(baseline.decode("utf-8")).encode("utf-8")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(result)
    except subprocess.CalledProcessError as error:
        print(f"Cannot read {BASELINE_REF}; make sure the CI checkout includes that tag.\n"
              f"{error.stderr.decode('utf-8', errors='replace').strip()}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Cannot prepare the chat baseline: {error}", file=sys.stderr)
        return 1

    print(f"Prepared {BASELINE_REF} chat + scroll identifier + DEBUG history probe: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
