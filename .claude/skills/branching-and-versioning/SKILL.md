---
name: branching-and-versioning
description: Enforce branch creation rules (do not create branches unless explicitly asked) and standardized semantic version increments based on change magnitude.
---

# Branching Policy and Versioning Guidelines

This skill defines mandatory rules for git branching and project versioning in Luthon.

## 1. Branch Creation Policy

- **Do NOT create new git branches or worktrees unless the user explicitly requests one.**
- Work directly on the active branch (typically `main`) for standard edits, fixes, improvements, and refactorings unless the user specifically asks to "create a branch", "work in a worktree", or names a branch.
- When the user asks to merge branches, merge them cleanly into `main` and sync with the remote repository.

## 2. Version Increment Policy

Versions follow the structure:
`[major/stable].[medium].[small]` (e.g., `0.3.0`, `1.0.0`)

- **Major / Stable (`X.0.0`)**:
  - Incremented on stable milestones, major architectural shifts, or breaking API redesigns.
- **Medium (`X.Y.0`)**:
  - Incremented on feature additions, new CLI flags (e.g. `--pure`), significant subsystem implementations (e.g., async/await lowerer, new native runtime capabilities), or substantial transpiler enhancements.
- **Small (`X.Y.Z`)**:
  - Incremented on bug fixes, small optimizations, documentation updates, or minor tweaks.

When delivering a feature or significant addition, bump the version in `pyproject.toml` and `src/luthon/__init__.py` (or wherever project version is tracked) according to these rules.
