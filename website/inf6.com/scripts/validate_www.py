#!/usr/bin/env python3
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]


class LinkCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for key, value in attrs:
            if key in {"href", "src"} and value:
                self.links.append((key, value))


def fail(message: str) -> None:
    print(f"validation error: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_no_appledouble() -> None:
    bad = sorted(path for path in ROOT.rglob("._*") if ".git" not in path.parts)
    if bad:
        fail("AppleDouble files must not be shipped:\n" + "\n".join(str(path) for path in bad[:20]))


def validate_html(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    parser = LinkCollector()
    parser.feed(text)
    for attr, value in parser.links:
        parsed = urlparse(value)
        if parsed.scheme in {"http", "https", "mailto", "tel"}:
            continue
        if value.startswith("#") or value.startswith("data:"):
            continue
        target = (ROOT / parsed.path.lstrip("/")).resolve()
        try:
            target.relative_to(ROOT)
        except ValueError:
            fail(f"{path}: {attr} points outside www root: {value}")
        if parsed.path and not target.exists():
            fail(f"{path}: missing local {attr}: {value}")


def validate_storage_contract() -> None:
    index = (ROOT / "index.html").read_text(encoding="utf-8")
    forbidden = [
        "iCloud Drive",
        "CloudDocs",
        "Mobile Documents",
        "same iCloud",
        "同じiCloud",
        "iCloud Drive へファイル保存",
    ]
    for token in forbidden:
        if token in index:
            fail(f"index.html still contains forbidden storage wording: {token}")
    if "Zip export/import" not in index:
        fail("index.html must describe Zip export/import sharing")
    if "local folder" not in index and "ローカルフォルダ" not in index:
        fail("index.html must describe local folder storage")


def main() -> None:
    for required in ["index.html", "legal.html", "README.md", "azure-pipelines.yml"]:
        if not (ROOT / required).is_file():
            fail(f"required file is missing: {required}")
    validate_no_appledouble()
    for html in sorted(ROOT.glob("*.html")):
        validate_html(html)
    validate_storage_contract()
    print("WWW validation passed")


if __name__ == "__main__":
    main()
