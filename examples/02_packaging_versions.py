"""
Advanced Example 2: Domain Modeling & Packaging Utilities
Using 'packaging' library (installed via luthon-pip) to test version comparisons.
"""

from packaging.version import parse as parse_version

def demonstrate_packaging():
    v1 = parse_version("1.2.0")
    v2 = parse_version("1.10.0")
    v3 = parse_version("2.0.0a1")

    # Version comparison logic
    assert v1 < v2
    assert v2 < v3
    assert v1.base_version == "1.2.0"
    assert v2.base_version == "1.10.0"
    assert v3.is_prerelease == True

    print("EXAMPLE_2_PACKAGING_OK: v1 < v2 < v3 verified")

if __name__ == "__main__":
    demonstrate_packaging()
