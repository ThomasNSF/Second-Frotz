#!/usr/bin/env python3
"""Convert a binary Z-machine story file into ROM notecards.

Second Life notecards are limited to 65,536 bytes, so a story is split
across numbered cards ("<name>.1", "<name>.2", ...) of at most
--pages-per-card pages each. Every card carries its own header line.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import math
from pathlib import Path

ROM_MAGIC = "ZROM1"
FORMAT_VERSION = 1
PAGE_SIZE = 762
PAGES_PER_CARD = 64
NOTECARD_LIMIT = 65536  # bytes; a card must stay strictly below this


def build_notecards(
    story: bytes,
    page_size: int = PAGE_SIZE,
    pages_per_card: int = PAGES_PER_CARD,
) -> list[str]:
    """Return the text of each card for a binary story.

    Every card starts with the header
    ``ZROM1|1|pageSize|pageCount|sha256|part|parts|pagesPerCard``
    followed by up to ``pages_per_card`` Base64 page lines.
    """
    if page_size <= 0 or page_size % 3 != 0:
        raise ValueError("page_size must be positive and divisible by 3")
    if pages_per_card <= 0:
        raise ValueError("pages_per_card must be positive")

    page_count = math.ceil(len(story) / page_size)
    parts = math.ceil(page_count / pages_per_card)
    checksum = hashlib.sha256(story).hexdigest()

    pages = []
    for offset in range(0, len(story), page_size):
        page = story[offset : offset + page_size].ljust(page_size, b"\x00")
        pages.append(base64.b64encode(page).decode("ascii"))

    cards = []
    for part in range(1, parts + 1):
        header = (
            f"{ROM_MAGIC}|{FORMAT_VERSION}|{page_size}|{page_count}|{checksum}"
            f"|{part}|{parts}|{pages_per_card}"
        )
        chunk = pages[(part - 1) * pages_per_card : part * pages_per_card]
        text = "\n".join([header] + chunk) + "\n"
        size = len(text.encode("ascii"))
        if size >= NOTECARD_LIMIT:
            raise ValueError(
                f"card {part} is {size} bytes; the limit is {NOTECARD_LIMIT} "
                f"(lower --pages-per-card)"
            )
        cards.append(text)

    return cards


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments for the converter."""
    parser = argparse.ArgumentParser(
        description="Convert a binary Z-machine story into numbered ROM notecards."
    )
    parser.add_argument("input", type=Path, help="Binary Z-machine story file")
    parser.add_argument(
        "output",
        type=Path,
        help='Notecard base name; cards are written as "<output>.1", "<output>.2", ...',
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=PAGE_SIZE,
        help=f"Page size in bytes; default: {PAGE_SIZE}",
    )
    parser.add_argument(
        "--pages-per-card",
        type=int,
        default=PAGES_PER_CARD,
        help=f"Maximum pages on one card; default: {PAGES_PER_CARD}",
    )
    return parser.parse_args()


def main() -> None:
    """Read the story file, generate the cards, and write them to disk."""
    args = parse_args()
    story = args.input.read_bytes()
    cards = build_notecards(story, args.page_size, args.pages_per_card)

    for number, text in enumerate(cards, start=1):
        path = args.output.with_name(f"{args.output.name}.{number}")
        path.write_text(text, encoding="ascii", newline="\n")
        print(f"Wrote {path} ({len(text.encode('ascii'))} bytes)")

    page_count = math.ceil(len(story) / args.page_size)
    print(f"{page_count} pages from {len(story)} bytes in {len(cards)} card(s)")


if __name__ == "__main__":
    main()
