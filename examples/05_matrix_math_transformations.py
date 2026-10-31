"""
Advanced Example 5: High-Throughput Matrix Multiplication & 2D Vectorization
Demonstrates dense 2D matrix transformations with Python's @ (MatMult) operator.
"""

import ffi

def demonstrate_matrix_math():
    # 2x2 Transformation Matrices
    # Translation/Scale A = [[2.0, 0.0], [0.0, 3.0]]
    # Shear Matrix       B = [[1.0, 1.5], [0.0, 1.0]]
    A = matrix(2, 2, [2.0, 0.0, 0.0, 3.0])
    B = matrix(2, 2, [1.0, 1.5, 0.0, 1.0])

    # Matrix product using Python @ operator:
    # C = A @ B -> [[2.0, 3.0], [0.0, 3.0]]
    C = A @ B

    assert C.rows == 2
    assert C.cols == 2
    assert C[0] == 2.0
    assert C[1] == 3.0
    assert C[2] == 0.0
    assert C[3] == 3.0

    # Multiplying by vector/column matrix X = [[4.0], [2.0]]
    X = matrix(2, 1, [4.0, 2.0])
    Y = C @ X  # [[2.0*4.0 + 3.0*2.0], [0.0*4.0 + 3.0*2.0]] = [[14.0], [6.0]]

    assert Y.rows == 2
    assert Y.cols == 1
    assert Y[0] == 14.0
    assert Y[1] == 6.0

    print("EXAMPLE_5_MATRIX_MATMUL_OK: Y =", Y[0], Y[1])

if __name__ == "__main__":
    demonstrate_matrix_math()
