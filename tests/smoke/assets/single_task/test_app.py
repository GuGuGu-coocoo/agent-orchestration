#!/usr/bin/env python3
"""Smoke test asset: frozen test for app.py."""
from app import greeting, greet


def main():
    assert greeting() == "hello", f"unexpected greeting: {greeting()!r}"
    assert greet("worker") == "hello worker", f"unexpected greet: {greet('worker')!r}"
    print("test_app: OK")


if __name__ == "__main__":
    main()
