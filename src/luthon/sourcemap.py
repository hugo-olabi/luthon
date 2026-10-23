"""Source-map emitter (Phase 2 scaffolding).

Maps generated Lua line numbers back to original Python source positions.
Currently a thin container; full VLQ encoding TBD.
"""

from dataclasses import dataclass, field
from typing import List, Tuple


@dataclass
class Mapping:
    gen_line: int
    gen_col: int
    src_line: int
    src_col: int
    src_file: str = ""


@dataclass
class SourceMap:
    file: str = ""
    sources: List[str] = field(default_factory=list)
    mappings: List[Mapping] = field(default_factory=list)

    def add(self, gen_line, gen_col, src_line, src_col, src_file=""):
        self.mappings.append(Mapping(gen_line, gen_col, src_line, src_col, src_file))

    _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    def _vlq(self, value):
        # encode a single signed integer as VLQ
        result = ""
        value = (value << 1) if value >= 0 else ((-value) << 1) | 1
        while True:
            digit = value & 31
            value >>= 5
            if value > 0:
                digit |= 32
            result += self._B64[digit]
            if value == 0:
                break
        return result

    def to_dict(self):
        # group mappings by generated line
        by_gen = {}
        for m in self.mappings:
            by_gen.setdefault(m.gen_line, []).append(m)
        lines = []
        prev_src_line = 0
        prev_src_col = 0
        prev_src_idx = 0
        prev_gen_col = 0
        for gl in sorted(by_gen):
            segs = []
            for m in sorted(by_gen[gl], key=lambda x: x.gen_col):
                si = 0
                if m.src_file and m.src_file in self.sources:
                    si = self.sources.index(m.src_file)
                seg = self._vlq(m.gen_col - prev_gen_col)
                seg += self._vlq(si - prev_src_idx)
                seg += self._vlq(m.src_line - prev_src_line)
                seg += self._vlq(m.src_col - prev_src_col)
                segs.append(seg)
                prev_gen_col = m.gen_col
                prev_src_idx = si
                prev_src_line = m.src_line
                prev_src_col = m.src_col
            lines.append(",".join(segs))
            prev_gen_col = 0
        return {
            "version": 3,
            "file": self.file,
            "sources": self.sources,
            "mappings": ";".join(lines),
        }
