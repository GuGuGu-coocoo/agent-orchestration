#!/usr/bin/env python3
"""Smoke test asset: frozen test for the escalation case.

This file must not be edited or weakened; it is intentionally incompatible with
the Task's Desired Behavior ("hi!") so the worker has to escalate.
"""
from main import message


def main():
    assert message() == "hi", f"message() must be exactly 'hi', got {message()!r}"
    print("test_main: OK")


if __name__ == "__main__":
    main()
