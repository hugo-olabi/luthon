
import sys

def fib(n):
    if n <= 1:
        return n
    return fib(n - 1) + fib(n - 2)

print('Running main.py via Luthon under LuaJIT!')
for i in range(10):
    print(f'fib({i}) = {fib(i)}')
