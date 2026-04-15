import unicodedata
import re


def slugify(text: str) -> str:
    normalized = unicodedata.normalize('NFKD', text).encode('ascii', 'ignore').decode('ascii')
    lowercased = normalized.lower()
    replaced = re.sub(r'[^a-z0-9-]', '-', lowercased)
    collapsed = re.sub(r'-+', '-', replaced)
    stripped = collapsed.strip('-')
    return stripped


def test_unicode_accents():
    assert slugify("café crème") == "cafe-creme"


def test_special_chars():
    assert slugify("Hello, World! #2024") == "hello-world-2024"


def test_whitespace():
    assert slugify("  multiple   spaces  ") == "multiple-spaces"


def test_empty_input():
    assert slugify("") == ""
    assert slugify("   ") == ""