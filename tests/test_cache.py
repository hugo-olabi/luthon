import tempfile, os
from pathlib import Path
from luthon.cache import CompilationCache

def test_cache_hit_unchanged():
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / 'a.py'
        src.write_text('x = 1\n')
        cache = CompilationCache(os.path.join(d, 'cache'))
        cache.store(str(src), '-- lua', {})
        assert cache.lookup(str(src), {}) == '-- lua'

def test_cache_miss_changed():
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / 'a.py'
        src.write_text('x = 1\n')
        cache = CompilationCache(os.path.join(d, 'cache'))
        cache.store(str(src), '-- lua', {})
        src.write_text('x = 2\n')
        assert cache.lookup(str(src), {}) is None
