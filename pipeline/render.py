#!/usr/bin/env python3
"""
Render ${VAR} placeholders in deployment templates from the environment.

Used by CodeBuild to turn pipeline/taskdef.template.json and pipeline/appspec.yaml
into account-specific artifacts. Fails loudly on any unresolved placeholder so a
missing CodeBuild env var never becomes a silent "${TASK_ROLE_ARN}" string in a
task definition.

Usage: render.py <template> <output>
"""

import os
import re
import sys

PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)\}")


def main(src: str, dst: str) -> int:
    text = open(src, encoding="utf-8").read()
    missing = sorted({m for m in PLACEHOLDER.findall(text) if not os.environ.get(m)})
    if missing:
        print(f"render.py: unresolved placeholders in {src}: {', '.join(missing)}", file=sys.stderr)
        return 1
    rendered = PLACEHOLDER.sub(lambda m: os.environ[m.group(1)], text)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(rendered)
    print(f"render.py: {src} -> {dst}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
