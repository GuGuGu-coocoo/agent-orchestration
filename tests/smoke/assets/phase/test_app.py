"""Smoke test asset: frozen phase-A acceptance suite.

A01 requires uppercase() and test_uppercase().
A02 adds test_shutdown() for shutdown(seconds).
A03 adds test_farewell() for farewell(name).

This file is the acceptance evidence for phase A. Each Task may append its own
test function; existing assertions may not be weakened or deleted.
"""
from app import uppercase


def test_uppercase():
    assert uppercase("abc") == "ABC"
