#!/bin/bash
# 发版前检查:App 里所有弱链接(weak-import)的系统符号,在本机系统库里是否真的存在。
#
# 背景(v1.9.18 崩溃):新 SDK 把某些 API 标成 @backDeployed(before: macOS X),编译器生成
# 「系统 ≥ X 就调系统导出的符号,否则用 App 内回退实现」的代码,系统符号是弱引用。若某个系统
# 自称 ≥ X 但其库里缺这个符号(Xcode 27.2 SDK 的 Date.>= 对 macOS 27.2 26B5091g),弱引用为空,
# 运行到那里就跳到地址 0 崩溃。
#
# 判定:本机系统版本 ≥ SDK 版本时,SDK 里任何 API 的可用性门槛都不会高于本机,于是弱引用符号
# 在本机缺失 = 确定会崩 → 报错退出。本机比 SDK 旧时,缺失可能只是正常的「更新系统才有」,只提示。
#
# 用法: scripts/check-weak-imports.sh <Berth.app 或 Mach-O 文件>...
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <Berth.app|binary>..." >&2; exit 2; }

bins=()
for p in "$@"; do
  if [ -d "$p" ]; then
    while IFS= read -r f; do
      file -b "$f" | grep -q 'Mach-O' && bins+=("$f")
    done < <(find "$p/Contents/MacOS" "$p/Contents/Frameworks" -type f 2>/dev/null)
  else
    bins+=("$p")
  fi
done

os_ver=$(sw_vers -productVersion)
sdk_ver=$(xcrun --sdk macosx --show-sdk-version)
strict=$(python3 -I -c 'import sys; a,b=(tuple(int(x) for x in v.split(".")) for v in sys.argv[1:]); print(1 if a>=b else 0)' "$os_ver" "$sdk_ver")

status=0
for bin in "${bins[@]}"; do
  arch=$(uname -m)
  lipo "$bin" -verify_arch "$arch" 2>/dev/null || continue
  python3 -I - "$bin" "$arch" "$strict" "$os_ver" "$sdk_ver" <<'PY' || status=1
import ctypes, os, re, subprocess, sys
binary, arch, strict, os_ver, sdk_ver = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4], sys.argv[5]

def short(path):
    m = re.search(r'/([^/]+)\.framework/', path)
    if m: return m.group(1)
    base = os.path.basename(path)
    return re.sub(r'(\.[A-Z])?\.dylib$', '', base)

libs = {}
for line in subprocess.run(["otool", "-arch", arch, "-L", binary], capture_output=True, text=True, check=True).stdout.splitlines()[1:]:
    path = line.strip().split(" ")[0]
    if path.startswith("/"):
        libs.setdefault(short(path), path)

fix = subprocess.run(["xcrun", "dyld_info", "-arch", arch, "-fixups", binary], capture_output=True, text=True, check=True).stdout
weak = sorted({tok for l in fix.splitlines() if "weak-import" in l for tok in l.split() if "/_" in tok})

missing, handles = [], {}
for entry in weak:
    lib, sym = entry.split("/", 1)
    path = libs.get(lib)
    if path is None:
        continue  # @rpath 等自带库,不归系统管
    if path not in handles:
        try: handles[path] = ctypes.CDLL(path, mode=os.RTLD_LAZY)
        except OSError: handles[path] = None
    h = handles[path]
    name = sym[1:] if sym.startswith("_") else sym
    if h is None or not hasattr(h, name):
        missing.append((lib, sym))

label = os.path.basename(binary)
print(f"[weak-imports] {label}: {len(weak)} weak imports, {len(missing)} missing on macOS {os_ver} (SDK {sdk_ver})")
for lib, sym in missing:
    dem = subprocess.run(["xcrun", "swift-demangle", "--compact", sym], capture_output=True, text=True).stdout.strip()
    print(f"  {'ERROR' if strict else 'note '}  {lib}: {dem or sym}")
sys.exit(1 if (missing and strict) else 0)
PY
done

if [ $status -ne 0 ]; then
  echo "[weak-imports] FAIL: 上面的符号在本机(系统版本 ≥ SDK)缺失,运行到对应调用点会跳到地址 0 崩溃。换一种写法绕开该 API。" >&2
fi
exit $status
