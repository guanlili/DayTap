#!/bin/bash
# 开发环境自检。逐项打印 PASS / WARN / FAIL / INFO,不靠口头承诺。
#   ./scripts/env-check.sh           # 只查环境
#   ./scripts/env-check.sh --build   # 附带双 target 编译(较慢,约 1-2 分钟)
# 退出码:0 = 没有 FAIL;1 = 有 FAIL。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DO_BUILD=0
[ "${1:-}" = "--build" ] && DO_BUILD=1

FAILS=0
WARNS=0

pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILS=$((FAILS + 1)); }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; WARNS=$((WARNS + 1)); }
info() { printf "  \033[36mINFO\033[0m  %s\n" "$1"; }

echo "环境自检 @ $(hostname) / $(sw_vers -productVersion)"
echo

echo "[1] 编译工具链"
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  pass "xcodebuild 可用:$(xcodebuild -version 2>/dev/null | head -1)"
else
  fail "xcodebuild 不可用(只装了 CommandLineTools?需要完整 Xcode)"
fi

DEVDIR="$(xcode-select -p 2>/dev/null || echo none)"
case "$DEVDIR" in
  *.app/Contents/Developer) pass "xcode-select 指向 Xcode:$DEVDIR" ;;
  *) fail "xcode-select 未指向 Xcode:$DEVDIR(需 sudo xcode-select -s /Applications/Xcode.app)" ;;
esac

SDKS="$(xcodebuild -showsdks 2>/dev/null || true)"
if echo "$SDKS" | grep -q -- "-sdk iphoneos"; then
  pass "iOS SDK 存在($(echo "$SDKS" | grep -- "-sdk iphoneos" | head -1 | awk '{print $2}'))"
else
  fail "缺 iOS SDK"
fi
if echo "$SDKS" | grep -q -- "-sdk watchos"; then
  pass "watchOS SDK 存在(手表代码可编译)"
else
  fail "缺 watchOS SDK,手表 target 编不了(Settings → Platforms 里装 watchOS)"
fi

RUNTIMES="$(xcrun simctl list runtimes 2>/dev/null | grep -c '^watchOS\|^iOS' || true)"
if [ "${RUNTIMES:-0}" -gt 0 ]; then
  pass "已装 $RUNTIMES 个模拟器 runtime"
else
  info "未装模拟器 runtime —— 只编译不需要;要在本机跑界面再 xcodebuild -downloadPlatform iOS/watchOS"
fi

echo
echo "[2] GitHub 协作"
GH_BIN="$(command -v gh || echo /opt/homebrew/bin/gh)"
if "$GH_BIN" auth status >/dev/null 2>&1; then
  SCOPES="$("$GH_BIN" auth status 2>&1 | grep -i "Token scopes" || true)"
  if echo "$SCOPES" | grep -q "project"; then
    pass "gh 已登录且含 project scope(可改 Project 看板)"
  else
    warn "gh 已登录但缺 project scope:$SCOPES"
  fi
else
  fail "gh 未登录(需 gh auth login)"
fi

SSH_OUT="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -T git@github.com 2>&1 | head -1 || true)"
case "$SSH_OUT" in
  *successfully\ authenticated*) pass "SSH key 可用:$SSH_OUT" ;;
  *) warn "SSH 到 GitHub 不通(推送会退化为 HTTPS):$SSH_OUT" ;;
esac

echo
echo "[3] 项目与文档"
if [ -n "$(git config user.name 2>/dev/null)" ]; then
  pass "git 身份:$(git config user.name) <$(git config user.email)>"
else
  warn "git user.name 未配置"
fi

BRANCH="$(git branch --show-current 2>/dev/null)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ "$DIRTY" = "0" ]; then
  pass "工作区干净 @ $BRANCH"
else
  warn "工作区有 $DIRTY 项未提交 @ $BRANCH"
fi

git fetch -q origin 2>/dev/null || true
AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo '?')"
BEHIND="$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo '?')"
if [ "$AHEAD" = "0" ] && [ "$BEHIND" = "0" ]; then
  pass "与远端同步($BRANCH)"
else
  info "本地领先 $AHEAD / 落后 $BEHIND(相对 origin/$BRANCH)"
fi

SKILL_DIR="$HOME/Library/Application Support/DoubaoWork/Default/.doubaowork/agent_mode/workspace/.user_skills/devledger"
if [ -d "$SKILL_DIR" ]; then
  pass "devledger skill 就位:$SKILL_DIR"
else
  warn "devledger skill 不在预期位置:$SKILL_DIR"
fi
if [ -d "$HOME/.agents/skills/devledger" ]; then
  pass "~/.agents/skills/devledger 存在(与 AGENTS.md 一致)"
else
  warn "AGENTS.md 里写的 ~/.agents/skills/devledger 不存在(文档路径已过时)"
fi

if python3 -c "import openpyxl" >/dev/null 2>&1; then
  pass "openpyxl 可用(能导验收表)"
else
  warn "缺 openpyxl(记账不受影响,导 xlsx 会失败):python3 -m pip install openpyxl"
fi

FREE_GB="$(df -g / | awk 'NR==2 {print $4}')"
if [ "${FREE_GB:-0}" -ge 20 ]; then
  pass "磁盘余量 ${FREE_GB}GB"
else
  warn "磁盘仅剩 ${FREE_GB}GB(构建与 DerivedData 需要空间)"
fi

echo
echo "[4] 双 target 编译"
if [ "$DO_BUILD" = "1" ]; then
  if bash "$ROOT/scripts/build-smoke.sh" >/tmp/daytap-build.log 2>&1; then
    pass "双 target 编译通过(日志 /tmp/daytap-build.log)"
  else
    fail "编译失败,看 /tmp/daytap-build.log 最后 30 行"
    tail -30 /tmp/daytap-build.log 2>/dev/null | sed 's/^/      /'
  fi
else
  info "跳过(加 --build 才跑;或直接 ./scripts/build-smoke.sh)"
fi

echo
echo "[5] 本机结构性限制(装不出来,不是没装好)"
info "模拟器可编译/可启动/可截图/可读日志;WCSession 在配对模拟器上能激活(reachability=true)"
info "但模拟器无麦克风(录音起不来)、无可编程点按通道 —— 传输链路要么上 XCUITest,要么真机"
info "真机专属:录音质量、VAD 阈值、触觉、后台保活、双击/握拳/Action Button、耗电发热"

echo
echo "结果:FAIL=$FAILS WARN=$WARNS"
[ "$FAILS" -eq 0 ] || exit 1
