import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shed_web  # noqa: E402


class ShedWebTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="shed-web-py-")
        self.cmd = Path(self.tmp.name) / "shed-web"
        self.cmd.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys\n"
            "args = sys.argv[1:]\n"
            "if 'boom' in args:\n"
            "    sys.stderr.write('shed-web: bad gateway\\n')\n"
            "    sys.exit(1)\n"
            "if args[0] == 'search':\n"
            "    print(json.dumps({'sources': [{'url': 'https://example.com', 'argv': args}]}))\n"
            "else:\n"
            "    print(json.dumps({'url': args[-3], 'statusCode': 200, 'markdown': 'ok', 'argv': args}))\n"
        )
        self.cmd.chmod(self.cmd.stat().st_mode | stat.S_IXUSR)
        self.old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{self.tmp.name}:{self.old_path}"

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.tmp.cleanup()

    def test_search_passes_double_dash_and_flags(self):
        hits = shed_web.search("--locked flag", limit=3, sources=["web", "news"], scrape=True)
        self.assertEqual(
            hits[0]["argv"],
            ["search", "--limit", "3", "--sources", "web,news", "--scrape", "--", "--locked flag", "--json", "--full"],
        )

    def test_fetch_passes_formats_and_strips_error_prefix(self):
        page = shed_web.fetch("https://example.com", formats=["markdown", "links"], all_content=True, timeout=5000)
        self.assertEqual(
            page["argv"],
            [
                "fetch",
                "--format",
                "markdown,links",
                "--all-content",
                "--timeout",
                "5000",
                "--",
                "https://example.com",
                "--json",
                "--full",
            ],
        )
        with self.assertRaises(shed_web.WebError) as ctx:
            shed_web.search("boom")
        self.assertEqual(str(ctx.exception), "bad gateway")


if __name__ == "__main__":
    unittest.main()
