#!/usr/bin/env python3
"""
check_286_opcodes.py — Static Gatekeeper for Intel 80286 Code Generation.

Prevents the #1 LLM failure mode in 16-bit x86 OS development: accidental
emission of 80386+ registers, instructions, or gcc -m16 0x66/0x67 prefixes
that silently work in QEMU (i386) but trigger #UD (INT 6) on a real 80286.

Usage:
    python tools/check_286_opcodes.py --asm boot/ kernel/
    python tools/check_286_opcodes.py --disasm build/kernel.dis
"""

import argparse
import pathlib
import re
import sys

# Forbidden 386+ registers and mnemonics in assembly or disassembly
FORBIDDEN_REGISTERS = re.compile(
    r"\b("
    r"eax|ebx|ecx|edx|esi|edi|ebp|esp|eip|eflags|"
    r"cr0|cr2|cr3|cr4|dr0|dr1|dr2|dr3|dr6|dr7|"
    r"fs|gs"
    r")\b",
    re.IGNORECASE,
)

FORBIDDEN_MNEMONICS = re.compile(
    r"\b("
    r"movzx|movsx|shld|shrd|bsf|bsr|bt|bts|btr|btc|"
    r"cmpxchg|xadd|bswap|cpuid|invlpg|wbinvd|rdmsr|wrmsr|rdtsc|"
    r"iretd|pushad|popad|pushfd|popfd|cwde|cdq|"
    r"lfs|lgs|lss|seta|setae|setb|setbe|setc|sete|setg|setge|"
    r"setl|setle|setna|setnae|setnb|setnbe|setnc|setne|setng|setnge|"
    r"setnl|setnle|setno|setnp|setns|setnz|seto|setp|setpe|setpo|sets|setz|"
    r"o32|a32"
    r")\b",
    re.IGNORECASE,
)

CPU_286_DIRECTIVE = re.compile(r"^\s*CPU\s+286\b", re.IGNORECASE | re.MULTILINE)


def strip_asm_comments_and_strings(line: str) -> str:
    """Remove assembly comments (; or //) and quoted string literals."""
    in_single = False
    in_double = False
    out = []
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(" ")
        elif ch == '"' and not in_single:
            in_double = not in_double
            out.append(" ")
        elif not in_single and not in_double:
            if ch == ";":
                break
            if ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
                break
            out.append(ch)
        else:
            out.append(" ")
        i += 1
    return "".join(out)


def check_asm_file(path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")

    if path.suffix.lower() in {".asm", ".nasm"}:
        if not CPU_286_DIRECTIVE.search(text):
            errors.append(
                f"{path}:1: Missing mandatory 'CPU 286' directive at top of file"
            )

    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        code = strip_asm_comments_and_strings(raw_line)
        if not code.strip():
            continue

        reg_match = FORBIDDEN_REGISTERS.search(code)
        if reg_match:
            errors.append(
                f"{path}:{lineno}: Forbidden 80386+ register '{reg_match.group(0)}' in: {raw_line.strip()}"
            )

        mnem_match = FORBIDDEN_MNEMONICS.search(code)
        if mnem_match:
            errors.append(
                f"{path}:{lineno}: Forbidden 80386+ instruction/prefix '{mnem_match.group(0)}' in: {raw_line.strip()}"
            )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate strict 80286 instruction compliance.")
    parser.add_argument(
        "--asm",
        nargs="+",
        default=[],
        help="Directories or .asm/.S files to scan for 80286 compliance.",
    )
    parser.add_argument(
        "--disasm",
        nargs="+",
        default=[],
        help="Disassembly listing files (from ndisasm -b 16 or objdump -m i8086) to verify.",
    )
    args = parser.parse_args()

    all_errors: list[str] = []

    for item in args.asm:
        p = pathlib.Path(item)
        if not p.exists():
            continue
        files = (
            [p]
            if p.is_file()
            else [
                f
                for f in p.rglob("*")
                if f.suffix.lower() in {".asm", ".nasm", ".s"}
            ]
        )
        for f in files:
            all_errors.extend(check_asm_file(f))

    for item in args.disasm:
        p = pathlib.Path(item)
        if p.is_file():
            all_errors.extend(check_asm_file(p))

    if all_errors:
        print("80286 Compliance Check FAILED:", file=sys.stderr)
        for err in all_errors:
            print(f"  [ERROR] {err}", file=sys.stderr)
        return 1

    print("80286 Compliance Check PASSED (0 forbidden 386+ instructions or prefixes).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
