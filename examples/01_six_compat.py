"""
Advanced Example 1: Pure-Python and Pip Library Interoperability
Using 'six' compatibility library installed via luthon-pip.
"""

import six

def demonstrate_six():
    # String types check
    test_str = "Luthon Transpiler"
    assert isinstance(test_str, str)
    assert six.PY2 == False
    assert six.PY3 == True

    # Dictionary iteration helpers
    d = {"alpha": 1, "beta": 2, "gamma": 3}
    keys = list(six.iterkeys(d))
    values = list(six.itervalues(d))
    items = list(six.iteritems(d))

    assert len(keys) == 3
    assert len(values) == 3
    assert len(items) == 3

    # Six text / binary conversion
    text_val = six.u("hello world")
    assert text_val == "hello world"

    print("EXAMPLE_1_SIX_OK: keys =", len(keys), "values =", len(values))

if __name__ == "__main__":
    demonstrate_six()
