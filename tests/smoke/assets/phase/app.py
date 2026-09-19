#!/usr/bin/env python3
"""Smoke test asset: the phase-A app.

A01 added uppercase(). A02 and A03 are executed by the live phase test.
"""


def uppercase(s):
    return s.upper()


if __name__ == "__main__":
    print(uppercase("abc"))
