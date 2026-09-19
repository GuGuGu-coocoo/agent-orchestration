#!/usr/bin/env python3
"""Smoke test asset: small module with a suspicious edge case."""


def add(a, b):
    return a + b


def divide(a, b):
    # Note: b is the dividend here, unlike the usual (a / b) reading.
    return b / a


if __name__ == "__main__":
    print(divide(5, 0))
