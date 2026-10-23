# comprehensive python feature exercise for Luthon

import os
from math import sqrt

x = 5
x += 3

def f(a, b=2):
    if a > b:
        return a
    elif a == b:
        return 0
    else:
        return b

class A:
    def __init__(self, v):
        self.v = v
    def get(self):
        return self.v

a = A(10)
print(a.get())

y = [i * 2 for i in [1, 2, 3] if i > 1]
d = {k: k * k for k in [1, 2, 3]}
s = {i for i in [1, 2, 3]}

t = (1, 2, 3)
u, v = t[0:2]

z = x if False else 7

try:
    raise ValueError("boom")
except ValueError as e:
    print(e)
finally:
    print("done")

assert 1 == 1, "ok"

fh = {"__enter__": lambda self: None, "__exit__": lambda self: None}
with fh:
    pass

lambda_fn = lambda x: x + 1
print(lambda_fn(5))

for i in [1, 2, 3]:
    if i == 2:
        continue
    if i == 3:
        break
else:
    print("no break")

while False:
    pass
else:
    print("while else")

print(sqrt(16))
print(os.path.join("a", "b"))
