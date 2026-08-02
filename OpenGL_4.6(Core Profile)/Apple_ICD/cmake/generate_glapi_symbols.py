#!/usr/bin/env python3

import sys
import xml.etree.ElementTree as ET

EXCLUDED_SYMBOLS = {
    "glMultiDrawArraysIndirectCount",
    "glMultiDrawArraysIndirectCountARB",
    "glMultiDrawElementsIndirectCount",
    "glMultiDrawElementsIndirectCountARB",
}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_glapi_symbols.py <gl.xml> <output>", file=sys.stderr)
        return 1

    root = ET.parse(sys.argv[1]).getroot()
    seen = set()

    with open(sys.argv[2], "w", encoding="utf-8") as output:
        for command in root.findall(".//commands/command"):
            name_elem = command.find("./proto/name")
            if name_elem is None or not name_elem.text:
                continue

            name = name_elem.text.strip()
            if not name or name in seen or name in EXCLUDED_SYMBOLS:
                continue

            seen.add(name)
            output.write(name)
            output.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
