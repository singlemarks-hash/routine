#!/usr/bin/env python3
"""G0 한글 잔존 래칫 — 영어화 진행의 역행 방지 게이트.

문자열 리터럴 '안'의 한글만 찾는다 (주석 속 한글은 허용 — 코드 문서화는 한국어 유지).
scripts/l10n_allowlist.txt 에 '아직 영어화 전'인 파일 목록을 두고:
  - 목록에 없는 파일에서 한글 리터럴 발견 → 실패 (새 한글 유입 차단)
  - 목록에 있는데 한글 리터럴이 없는 파일 → 실패 (영어화 완료 시 목록에서 제거 강제 = 래칫 전진)

사용법:
  python3 scripts/check_korean_residue.py            # 검사 (CI)
  python3 scripts/check_korean_residue.py --update   # 허용 목록 재생성 (로컬 시딩 전용)

한계(의도된 휴리스틱): 보간식 내부에 중첩된 따옴표("\\(flag ? "가" : "나")")는
상태 추적이 단순화되어 놓칠 수 있다. 파일 단위 불리언 게이트라 실질 영향 없음.

줄 단위 예외: 날짜 포맷 패턴("M월 d일" 등)처럼 ko 전용 분기 안에서 **영원히**
한글이어야 하는 리터럴은 `l10n:ko-literal` 마커 주석을 같은 줄에 달면 스캔에서
제외된다 (파일이 "번역 완료"로 잡히지 못하게 막는 것을 방지 — 이런 줄은 번역
대상이 아니라 설계상 항상 한글이다). 오남용 방지를 위해 한 줄짜리 문("dateFormat =
..." 등)에만 쓴다 — 그 줄 전체가 스캔에서 빠지므로 같은 줄에 다른 코드가 있으면 안 된다.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "l10n_allowlist.txt"
KOREAN = re.compile(r"[가-힣ㄱ-ㅎㅏ-ㅣ]")

SCAN_GLOBS = [
    ("TimeLock/TimeLock", "*.swift"),
    ("android/app/src/main/java", "*.kt"),
]


def string_literal_content(src: str) -> str:
    """주석을 제외하고 문자열 리터럴 내용만 이어붙여 반환.

    Swift/Kotlin 공통 최소 토크나이저: // 줄 주석, /* */ 중첩 블록 주석,
    "..." 한 줄 문자열(이스케이프 처리), \"\"\"...\"\"\" 여러 줄 문자열.
    """
    out = []
    i, n = 0, len(src)
    mode = "code"          # code | line | block | str | mstr
    depth = 0              # 블록 주석 중첩 (Swift/Kotlin 모두 중첩 허용)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if mode == "code":
            if c == "/" and nxt == "/":
                mode = "line"; i += 2
            elif c == "/" and nxt == "*":
                mode = "block"; depth = 1; i += 2
            elif c == '"':
                if src[i:i + 3] == '"""':
                    mode = "mstr"; i += 3
                else:
                    mode = "str"; i += 1
            else:
                i += 1
        elif mode == "line":
            if c == "\n":
                mode = "code"
            i += 1
        elif mode == "block":
            if c == "/" and nxt == "*":
                depth += 1; i += 2
            elif c == "*" and nxt == "/":
                depth -= 1; i += 2
                if depth == 0:
                    mode = "code"
            else:
                i += 1
        elif mode == "str":
            if c == "\\":
                i += 2                     # 이스케이프(\" 포함) 건너뜀
            elif c == '"' or c == "\n":    # 종료 또는 미종결 안전탈출
                mode = "code"; i += 1
            else:
                out.append(c); i += 1
        else:  # mstr
            if src[i:i + 3] == '"""':
                mode = "code"; i += 3
            else:
                out.append(c); i += 1
    return "".join(out)


LINE_EXCEPTION_MARKER = "l10n:ko-literal"


def strip_exception_lines(src: str) -> str:
    """마커가 붙은 줄을 통째로 비운다 (줄 번호 유지 — 이후 처리에 영향 없음)."""
    return "\n".join(
        "" if LINE_EXCEPTION_MARKER in line else line
        for line in src.split("\n")
    )


def files_with_korean_literals() -> set[str]:
    found = set()
    for base, pattern in SCAN_GLOBS:
        for f in sorted((ROOT / base).rglob(pattern)):
            rel = f.relative_to(ROOT).as_posix()
            try:
                src = f.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            src = strip_exception_lines(src)
            if KOREAN.search(string_literal_content(src)):
                found.add(rel)
    return found


def main() -> int:
    current = files_with_korean_literals()

    if "--update" in sys.argv:
        ALLOWLIST.write_text("\n".join(sorted(current)) + "\n", encoding="utf-8")
        print(f"허용 목록 재생성: {len(current)}개 파일 → {ALLOWLIST.relative_to(ROOT)}")
        return 0

    if not ALLOWLIST.exists():
        print("오류: 허용 목록이 없습니다. 먼저 --update 로 시딩하세요.")
        return 1
    allowed = {
        line.strip() for line in ALLOWLIST.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }

    regressions = sorted(current - allowed)   # 새 한글 유입
    stale = sorted(allowed - current)         # 영어화 끝났는데 목록 잔존

    ok = True
    if regressions:
        ok = False
        print("❌ 허용 목록에 없는 파일에서 한글 문자열 리터럴 발견 (새 유입 금지):")
        for f in regressions:
            print(f"   {f}")
    if stale:
        ok = False
        print("❌ 한글 리터럴이 더는 없는데 허용 목록에 남은 파일 (래칫 전진 — 목록에서 제거하세요):")
        for f in stale:
            print(f"   {f}")
    if ok:
        print(f"✅ G0 통과 — 한글 리터럴 보유 파일 {len(current)}개, 전부 허용 목록과 일치")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
