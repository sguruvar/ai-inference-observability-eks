#!/usr/bin/env python3
"""Validate that the local MCP entrypoint imports exported server symbols."""

from __future__ import annotations

import ast
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "mcp-server" / "server.py"
LOCAL_PATH = ROOT / "mcp-server" / "local.py"


def parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def assigned_names(target: ast.expr) -> set[str]:
    if isinstance(target, ast.Name):
        return {target.id}
    if isinstance(target, (ast.Tuple, ast.List)):
        return {name for item in target.elts for name in assigned_names(item)}
    return set()


def exported_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                names.update(assigned_names(target))
        elif isinstance(node, ast.AnnAssign):
            names.update(assigned_names(node.target))
    return names


def local_server_imports(tree: ast.Module) -> set[str]:
    imports: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "server":
            imports.update(alias.name for alias in node.names)
    return imports


def main() -> int:
    server_exports = exported_names(parse(SERVER_PATH))
    local_imports = local_server_imports(parse(LOCAL_PATH))
    missing = sorted(local_imports - server_exports)

    if missing:
        print(
            f"{LOCAL_PATH.relative_to(ROOT)} imports missing server symbols: "
            f"{', '.join(missing)}",
            file=sys.stderr,
        )
        return 1

    print("MCP local entrypoint imports are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
