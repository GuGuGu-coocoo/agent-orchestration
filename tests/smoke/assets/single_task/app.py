#!/usr/bin/env python3
"""Smoke test asset: a tiny greeting module."""


def greeting():
    return "hello"


def greet(name):
    return "hello " + name


if __name__ == "__main__":
    print(greeting())
