"""Luthon Compilation & Lowering Decision Diary (Phase 4 / Debugging).

Provides a comprehensive diagnostic diary of every compiler lowering decision:
1. Records why operations are lowered to native Lua/machine instructions vs safe runtime fallbacks (_luthon_*).
2. Explains type inference deductions, gradual type degradations, and operand constraints.
3. Diagnoses LuaJIT JIT hazards (such as anonymous closures, NYI constructs, dynamic lookups).
4. Emits detailed human-readable Markdown diaries and structured JSON reports into `.luthon-debug/`.
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


@dataclass
class DecisionRecord:
    func_name: str
    category: str  # "ARITHMETIC", "COMPARISON", "SUBSCRIPT", "SLICE", "BRANCH", "TRY_BLOCK", "DICT_MUTATION", "CALL"
    operation: str  # "+", "-", "==", "~=", "[:]", "cont[k]", "if cond", "pcall"
    choice: str  # "machine_add", "direct_cmp", "subscr_fast_index", "subscr_fast_key", "direct_branch", "string_sub", "safe_fallback"
    is_native: bool  # True if native machine code / direct Lua; False if safe runtime fallback (_luthon_*)
    reason: str  # Human-readable explanation of why this was chosen
    line: Optional[int] = None
    col: Optional[int] = None
    suggestion: Optional[str] = None  # Actionable advice to upgrade fallback to native


@dataclass
class TypeDiaryEntry:
    func_name: str
    var_name: str
    inferred_type: str
    is_concrete: bool
    reason: str


class LuthonDiary:
    """Collects compiler decisions and type deductions for a single module."""

    def __init__(self, module_name: str = "module", source_file: Optional[str] = None, debug_dir: Optional[str] = None):
        self.module_name = module_name
        self.source_file = source_file
        self.debug_dir = Path(debug_dir) if debug_dir else Path(os.getenv("LUTHON_DEBUG_DIR", ".luthon-debug"))
        self.decisions: List[DecisionRecord] = []
        self.type_records: List[TypeDiaryEntry] = []
        self.enabled: bool = os.getenv("LUTHON_DEBUG", "0") in ("1", "true", "True") or os.getenv("LUTHON_DEBUG_DIR") is not None or self.debug_dir.exists()

    def record_decision(
        self,
        func_name: str,
        category: str,
        operation: str,
        choice: str,
        is_native: bool,
        reason: str,
        line: Optional[int] = None,
        col: Optional[int] = None,
        suggestion: Optional[str] = None,
    ) -> None:
        rec = DecisionRecord(
            func_name=func_name,
            category=category,
            operation=operation,
            choice=choice,
            is_native=is_native,
            reason=reason,
            line=line,
            col=col,
            suggestion=suggestion,
        )
        self.decisions.append(rec)

    def record_type(
        self,
        func_name: str,
        var_name: str,
        inferred_type: str,
        is_concrete: bool,
        reason: str,
    ) -> None:
        self.type_records.append(
            TypeDiaryEntry(
                func_name=func_name,
                var_name=var_name,
                inferred_type=inferred_type,
                is_concrete=is_concrete,
                reason=reason,
            )
        )

    def export_json(self) -> Dict[str, Any]:
        native_count = sum(1 for d in self.decisions if d.is_native)
        fallback_count = len(self.decisions) - native_count
        ratio = (native_count / len(self.decisions) * 100.0) if self.decisions else 100.0

        return {
            "module_name": self.module_name,
            "source_file": self.source_file,
            "stats": {
                "total_operations": len(self.decisions),
                "native_operations": native_count,
                "fallback_operations": fallback_count,
                "native_percentage": round(ratio, 1),
            },
            "types": [asdict(t) for t in self.type_records],
            "decisions": [asdict(d) for d in self.decisions],
        }

    def export_markdown(self) -> str:
        native_count = sum(1 for d in self.decisions if d.is_native)
        fallback_count = len(self.decisions) - native_count
        total = len(self.decisions)
        ratio = (native_count / total * 100.0) if total else 100.0

        lines: List[str] = []
        lines.append(f"# Luthon Lowering & Decision Diary: `{self.module_name}`")
        if self.source_file:
            lines.append(f"**Source File**: `{self.source_file}`  ")
        lines.append(f"**Efficiency Score**: **{ratio:.1f}% Native** ({native_count} native, {fallback_count} safe fallbacks)")
        lines.append("")

        # 1. Summary of Fallbacks & Suggestions
        fallbacks = [d for d in self.decisions if not d.is_native]
        if fallbacks:
            lines.append("## ⚠️ Optimization Blockers & Fallbacks")
            lines.append("| Function | Line | Operation | Safe Fallback Chosen | Root Cause & Suggestion |")
            lines.append("| :--- | :--- | :--- | :--- | :--- |")
            for fb in fallbacks:
                loc = f"L{fb.line}" if fb.line else "-"
                sug = f"<br>💡 *Tip*: {fb.suggestion}" if fb.suggestion else ""
                lines.append(f"| `{fb.func_name}` | {loc} | `{fb.operation}` | `{fb.choice}` | {fb.reason}{sug} |")
            lines.append("")
        else:
            lines.append("## ✅ Zero Fallbacks Detected")
            lines.append("All analyzed operations in this module were lowered directly to native machine instructions!\n")

        # 2. Type Inference Diary
        if self.type_records:
            lines.append("## 🔍 Inferred Types & Signatures")
            lines.append("| Function | Variable / Parameter | Inferred Type | Concrete? | Reason / Source |")
            lines.append("| :--- | :--- | :--- | :--- | :--- |")
            for tr in self.type_records:
                status = "✅ Concrete" if tr.is_concrete else "❓ Gradual / Any"
                lines.append(f"| `{tr.func_name}` | `{tr.var_name}` | `{tr.inferred_type}` | {status} | {tr.reason} |")
            lines.append("")

        # 3. Comprehensive Decisions per Function
        funcs = sorted(list({d.func_name for d in self.decisions}))
        if funcs:
            lines.append("## 📋 Comprehensive Lowering Diary by Function")
            for fn in funcs:
                fn_decs = [d for d in self.decisions if d.func_name == fn]
                fn_native = sum(1 for d in fn_decs if d.is_native)
                fn_ratio = (fn_native / len(fn_decs) * 100.0) if fn_decs else 100.0
                lines.append(f"### Function `{fn}` ({fn_ratio:.1f}% native)")
                lines.append("| Line | Category | Operation | Status | Lowering Choice | Reason |")
                lines.append("| :--- | :--- | :--- | :--- | :--- | :--- |")
                for d in fn_decs:
                    loc = f"L{d.line}" if d.line else "-"
                    status = "⚡ **Native**" if d.is_native else "🛡️ Safe Fallback"
                    lines.append(f"| {loc} | {d.category} | `{d.operation}` | {status} | `{d.choice}` | {d.reason} |")
                lines.append("")

        return "\n".join(lines)

    def flush_to_debug_dir(self, target_dir: Optional[str] = None) -> Tuple[Optional[Path], Optional[Path]]:
        out_dir = Path(target_dir) if target_dir else self.debug_dir
        try:
            out_dir.mkdir(parents=True, exist_ok=True)
            safe_name = self.module_name.replace("/", "_").replace(".", "_")
            if safe_name.endswith("_py"):
                safe_name = safe_name[:-3]

            md_path = out_dir / f"{safe_name}.diary.md"
            json_path = out_dir / f"{safe_name}.decisions.json"

            md_path.write_text(self.export_markdown(), encoding="utf-8")
            json_path.write_text(json.dumps(self.export_json(), indent=2), encoding="utf-8")
            return md_path, json_path
        except Exception:
            return None, None


_ACTIVE_DIARY: Optional[LuthonDiary] = None


def get_active_diary() -> Optional[LuthonDiary]:
    global _ACTIVE_DIARY
    return _ACTIVE_DIARY


def start_diary(module_name: str, source_file: Optional[str] = None, debug_dir: Optional[str] = None, force: bool = False) -> LuthonDiary:
    global _ACTIVE_DIARY
    diary = LuthonDiary(module_name=module_name, source_file=source_file, debug_dir=debug_dir)
    if force:
        diary.enabled = True
    _ACTIVE_DIARY = diary
    return diary


def stop_diary(flush: bool = True, target_dir: Optional[str] = None) -> Optional[LuthonDiary]:
    global _ACTIVE_DIARY
    diary = _ACTIVE_DIARY
    if diary and flush and (diary.enabled or diary.decisions):
        diary.flush_to_debug_dir(target_dir=target_dir)
    _ACTIVE_DIARY = None
    return diary
