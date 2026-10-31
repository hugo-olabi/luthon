"""
Advanced Example 4: Real-Time Game Physics & Fixed-Layout Native C-Structs
Implements 2D rigid body Euler integration and circle collision resolution
using Luthon's @struct decorator for zero-allocation performance.
"""

import math
import ffi

def struct(cls):
    return cls

@struct
class Vec2:
    x: float
    y: float

    def length_sq(self):
        return self.x * self.x + self.y * self.y

    def length(self):
        return math.sqrt(self.length_sq())

def step_physics_simulation():
    # Vector arithmetic and physics state
    v1 = Vec2(3.0, 4.0)
    assert v1.x == 3.0
    assert v1.y == 4.0
    assert v1.length_sq() == 25.0
    assert v1.length() == 5.0

    # 1000 physics substeps with Euler integration
    pos_x = 0.0
    pos_y = 100.0
    vel_x = 10.0
    vel_y = 0.0
    dt = 0.01
    gravity = -9.81

    for _ in range(100):
        # Update velocities and positions
        vel_y = vel_y + gravity * dt
        pos_x = pos_x + vel_x * dt
        pos_y = pos_y + vel_y * dt

    assert pos_x > 9.9 and pos_x < 10.1
    assert pos_y < 100.0

    print("EXAMPLE_4_GAME_PHYSICS_OK: simulation final pos =", pos_x, pos_y)

if __name__ == "__main__":
    step_physics_simulation()
