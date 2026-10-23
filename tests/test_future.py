from luthon.semantic import analyze, future_features


def test_future_imports_recorded():
    src = """
from __future__ import annotations
from __future__ import division
from __future__ import print_function
x = 1
"""
    root = analyze(src)
    assert "annotations" in root.future_features
    assert "division" in root.future_features
    assert "print_function" in root.future_features


def test_future_features_function():
    src = "from __future__ import annotations\nx = 1\n"
    feats = future_features(src)
    assert "annotations" in feats


def test_future_import_with_other_imports():
    src = """
from __future__ import annotations
import os
from __future__ import division
from sys import path
"""
    root = analyze(src)
    assert "annotations" in root.future_features
    assert "division" in root.future_features
    # regular imports should still work
    assert "os" in root.locals


def test_no_future_imports():
    src = "x = 1\n"
    root = analyze(src)
    assert root.future_features == set()
    assert future_features(src) == set()
