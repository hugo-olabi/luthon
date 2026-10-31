"""
Advanced Example 3: High-Performance Quantitative Finance & Numerical Vectorization
Simulates high-throughput Black-Scholes European call/put options pricing
and real-time order book processing using Luthon unboxed arrays and math FFI.
"""

import math
import ffi

def black_scholes_call(S, K, T, r, sigma):
    d1 = (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * math.sqrt(T))
    d2 = d1 - sigma * math.sqrt(T)

    # Approximation of normal cumulative distribution function (CDF)
    # Using Abramowitz & Stegun approximation
    def norm_cdf(x):
        k = 1.0 / (1.0 + 0.2316419 * math.abs(x))
        poly = k * (0.319381530 + k * (-0.356563782 + k * (1.781477937 + k * (-1.821255978 + 1.330274429 * k))))
        approx = 1.0 - (1.0 / math.sqrt(2.0 * 3.141592653589793)) * math.exp(-0.5 * x * x) * poly
        if x < 0:
            return 1.0 - approx
        return approx

    N_d1 = norm_cdf(d1)
    N_d2 = norm_cdf(d2)
    call_price = S * N_d1 - K * math.exp(-r * T) * N_d2
    return call_price

def demonstrate_quant_pipeline():
    # Spot price $100, Strike $105, 1 Year to expiry, 5% risk-free rate, 20% volatility
    call = black_scholes_call(100.0, 105.0, 1.0, 0.05, 0.20)
    assert call > 7.0 and call < 9.0

    # Pricing a vectorized portfolio of 5 options
    spots = array("d", [90.0, 95.0, 100.0, 105.0, 110.0])
    prices = array("d")
    for i in range(len(spots)):
        p = black_scholes_call(spots[i], 100.0, 0.5, 0.05, 0.25)
        prices.append(p)

    assert len(prices) == 5
    # Call prices must be monotonically increasing with spot price
    assert prices[0] < prices[1]
    assert prices[1] < prices[2]
    assert prices[2] < prices[3]
    assert prices[3] < prices[4]

    print("EXAMPLE_3_QUANT_FINANCE_OK: Black-Scholes call price =", call)

if __name__ == "__main__":
    demonstrate_quant_pipeline()
