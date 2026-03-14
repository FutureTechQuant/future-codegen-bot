#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def copy_tree_contents(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target)


def find_frontend_src_dirs(generated_dir: Path) -> list[Path]:
    return [p for p in generated_dir.rglob("src") if p.parent.name == "yudao-ui-admin-vue3"]


def find_backend_modules(generated_dir: Path) -> list[Path]:
    modules: list[Path] = []
    for p in generated_dir.rglob("yudao-module-*"):
        if p.is_dir() and p.name.startswith("yudao-module-"):
            modules.append(p)
    modules.sort()
    return modules


def ensure_module_pom(backend_root: Path, module_name: str) -> None:
    module_dir = backend_root / module_name
    target_pom = module_dir / "pom.xml"
    if target_pom.exists():
        return

    template_pom = backend_root / "yudao-module-member" / "pom.xml"
    if not template_pom.exists():
        raise FileNotFoundError(f"template pom not found: {template_pom}")

    content = template_pom.read_text(encoding="utf-8")
    content = content.replace("yudao-module-member", module_name)
    content = content.replace(
        "member 模块，我们放会员业务。",
        f"{module_name.removeprefix('yudao-module-')} 模块，自动生成。"
    )
    content = content.replace(
        "例如说：会员中心等等",
        f"例如说：{module_name.removeprefix('yudao-module-')} 业务。"
    )
    target_pom.write_text(content, encoding="utf-8")


def insert_before_first(text: str, needle: str, block: str) -> str:
    if needle not in text:
        return text
    return text.replace(needle, block + needle, 1)


def ensure_root_module_declared(backend_root: Path, module_name: str) -> None:
    root_pom = backend_root / "pom.xml"
    content = root_pom.read_text(encoding="utf-8")
    marker = f"<module>{module_name}</module>"
    if marker in content:
        return

    block = f"        <module>{module_name}</module>\n"
    updated = insert_before_first(content, "    </modules>", block)
    root_pom.write_text(updated, encoding="utf-8")


def ensure_server_dependency(backend_root: Path, module_name: str) -> None:
    server_pom = backend_root / "yudao-server" / "pom.xml"
    content = server_pom.read_text(encoding="utf-8")
    marker = f"<artifactId>{module_name}</artifactId>"
    if marker in content:
        return

    block = f"""
        <dependency>
            <groupId>cn.iocoder.boot</groupId>
            <artifactId>{module_name}</artifactId>
            <version>${{revision}}</version>
        </dependency>
"""
    updated = insert_before_first(content, "    </dependencies>", block)
    server_pom.write_text(updated, encoding="utf-8")


def sync_frontend(generated_dir: Path, frontend_root: Path) -> None:
    src_dirs = find_frontend_src_dirs(generated_dir)
    target_src = frontend_root / "src"
    target_src.mkdir(parents=True, exist_ok=True)

    if not src_dirs:
        print("No generated frontend src found")
        return

    for src_dir in src_dirs:
        copy_tree_contents(src_dir, target_src)
        print(f"Synced frontend src from {src_dir}")


def sync_backend(generated_dir: Path, backend_root: Path) -> None:
    modules = find_backend_modules(generated_dir)

    if not modules:
        print("No generated backend modules found")
        return

    for module_dir in modules:
        module_name = module_dir.name
        target_module_dir = backend_root / module_name
        target_module_dir.mkdir(parents=True, exist_ok=True)

        copy_tree_contents(module_dir, target_module_dir)
        ensure_module_pom(backend_root, module_name)
        ensure_root_module_declared(backend_root, module_name)
        ensure_server_dependency(backend_root, module_name)

        print(f"Synced backend module {module_name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generated-dir", required=True)
    parser.add_argument("--backend-root", required=True)
    parser.add_argument("--frontend-root", required=True)
    args = parser.parse_args()

    generated_dir = Path(args.generated_dir).resolve()
    backend_root = Path(args.backend_root).resolve()
    frontend_root = Path(args.frontend_root).resolve()

    if not generated_dir.exists():
        raise FileNotFoundError(f"generated dir not found: {generated_dir}")
    if not backend_root.exists():
        raise FileNotFoundError(f"backend root not found: {backend_root}")
    if not frontend_root.exists():
        raise FileNotFoundError(f"frontend root not found: {frontend_root}")

    sync_frontend(generated_dir, frontend_root)
    sync_backend(generated_dir, backend_root)


if __name__ == "__main__":
    main()
