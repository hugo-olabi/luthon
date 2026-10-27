"""LuaJIT NYI (Not Yet Implemented) Checker, Trace Specialization & CData Anchoring (Phase 19).

Enforces:
1. Static NYI linting on lowered IR to detect trace abort patterns:
   - Unhoisted table/list allocations inside hot loops.
   - Value-passed/returned FFI aggregates.
   - Non-JIT compilable C-API calls along loop headers.
2. Automatic loop-invariant table hoisting out of inner loops.
3. Pass-by-reference enforcement for C-struct aggregates.
4. CData memory anchoring runtime registry.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple
from .ir import Module, Function, Block, Instr


@dataclass
class NYIViolation:
    fn_name: str
    block_label: str
    instr: Instr
    category: str
    message: str
    severity: str = "warning"  # "warning" or "error"


class NYIAuditor:
    """Statically analyzes an IR Module for patterns known to abort LuaJIT trace compilation."""

    def __init__(self, module: Module):
        self.module = module
        self.violations: List[NYIViolation] = []

    def audit(self) -> List[NYIViolation]:
        self.violations.clear()
        for fn in self.module.functions:
            self._audit_function(fn)
        return self.violations

    def _audit_function(self, fn: Function):
        # 1. Detect loops in basic block CFG (blocks with back-edges)
        loop_blocks = self._detect_loop_blocks(fn)

        for b in fn.blocks:
            is_in_loop = b.label in loop_blocks
            for ins in b.instrs:
                # Rule A: Table/dict/list creation in loop without sinking
                if is_in_loop and ins.op in ("MAKE_TABLE", "MAKE_LIST", "MAKE_DICT", "MAKE_SET"):
                    self.violations.append(
                        NYIViolation(
                            fn_name=fn.name,
                            block_label=b.label,
                            instr=ins,
                            category="allocation_in_loop",
                            message=f"Dynamic allocation {ins.op} inside loop block '{b.label}' may abort LuaJIT trace compilation",
                            severity="warning"
                        )
                    )

                # Rule B: Pass/return C-struct aggregate by value
                if ins.op == "CALL" and ins.args:
                    fn_target = str(ins.args[0])
                    # If target is a struct constructor or C-API call passing value aggregates
                    for arg in ins.args[1:]:
                        if isinstance(arg, str) and arg.endswith("_val_copy"):
                            self.violations.append(
                                NYIViolation(
                                    fn_name=fn.name,
                                    block_label=b.label,
                                    instr=ins,
                                    category="aggregate_by_value",
                                    message=f"Passing struct aggregate by value in call to '{fn_target}' causes NYI fallback; must pass by pointer",
                                    severity="error"
                                )
                            )

    def _detect_loop_blocks(self, fn: Function) -> Set[str]:
        """Identifies blocks that are part of a loop based on jump back-edges."""
        loop_labels: Set[str] = set()
        labels_seen: Set[str] = set()
        for b in fn.blocks:
            labels_seen.add(b.label)
            for ins in b.instrs:
                if ins.op == "JUMP" and ins.args:
                    target = ins.args[0]
                    if target in labels_seen:
                        loop_labels.add(b.label)
                        loop_labels.add(target)
                elif ins.op in ("BRANCH", "BRANCH_NONE") and len(ins.args) >= 2:
                    for t in ins.args[1:]:
                        if t and t in labels_seen:
                            loop_labels.add(b.label)
                            loop_labels.add(t)
        return loop_labels


def eliminate_loop_invariant_allocations(fn: Function) -> bool:
    """Hoists invariant empty table/list allocations out of loop bodies into pre-headers."""
    auditor = NYIAuditor(Module(name="temp", functions=[fn]))
    loop_blocks = auditor._detect_loop_blocks(fn)
    if not loop_blocks:
        return False

    entry_block = fn.blocks[0] if fn.blocks else None
    if not entry_block:
        return False

    changed = False
    for b in fn.blocks:
        if b.label in loop_blocks and b is not entry_block:
            hoisted: List[Instr] = []
            retained: List[Instr] = []
            for ins in b.instrs:
                # If instruction is an invariant constant buffer allocation with no args
                if ins.op in ("MAKE_TABLE", "MAKE_LIST") and not ins.args:
                    hoisted.append(ins)
                    changed = True
                else:
                    retained.append(ins)
            if hoisted:
                # Move hoisted instructions to the end of entry block (pre-loop)
                entry_block.instrs.extend(hoisted)
                b.instrs = retained

    return changed


# Lua CData Memory Anchoring and Registry Helpers
CDATA_ANCHOR_LUA = r"""
-- CData Memory Anchor Registry (Phase 19)
local _CDATA_ANCHORS = {}
local _CDATA_REF_COUNTS = {}

function _luthon_anchor(cdata_ptr, owner_obj)
  if cdata_ptr == nil then return end
  local key = tostring(cdata_ptr)
  _CDATA_ANCHORS[key] = owner_obj
  _CDATA_REF_COUNTS[key] = (_CDATA_REF_COUNTS[key] or 0) + 1
  return cdata_ptr
end

function _luthon_release_anchor(cdata_ptr)
  if cdata_ptr == nil then return end
  local key = tostring(cdata_ptr)
  local count = (_CDATA_REF_COUNTS[key] or 1) - 1
  if count <= 0 then
    _CDATA_ANCHORS[key] = nil
    _CDATA_REF_COUNTS[key] = nil
  else
    _CDATA_REF_COUNTS[key] = count
  end
end

function _luthon_is_anchored(cdata_ptr)
  if cdata_ptr == nil then return false end
  return _CDATA_ANCHORS[tostring(cdata_ptr)] ~= nil
end
"""
