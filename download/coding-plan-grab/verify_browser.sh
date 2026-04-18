#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan - 预验证脚本 v3
# 
# 关键改进：确保 browser_state 不被 close 操作破坏
# 流程：备份 → 加载 → 检查 → save → close → 验证state完整性 → 必要时恢复
# ============================================================

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
BROWSER_STATE_BACKUP="/home/z/my-project/download/coding-plan-grab/browser_state_backup.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/verify_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
BUY_PAGE="https://common-buy.aliyun.com/coding-plan"
SCREENSHOT_DIR="/home/z/my-project/download/coding-plan-grab"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 阿里百炼 Coding Plan 预验证 v3 ==="
ERRORS=0

# ============================================================
# 1. 备份现有 browser_state（关键！）
# ============================================================
if [ ! -f "$BROWSER_STATE" ]; then
    log "FATAL: browser_state.json 不存在！需要重新登录"
    echo "VERIFY_FAILED: no_browser_state" > "$STATUS_FILE"
    exit 1
fi

STATE_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
cp "$BROWSER_STATE" "$BROWSER_STATE_BACKUP"
log "browser_state: $(du -h "$BROWSER_STATE" | cut -f1) ($STATE_SIZE bytes) → 已备份"

if [ "$STATE_SIZE" -lt 100000 ]; then
    log "FATAL: browser_state 太小(${STATE_SIZE}B)，可能已失效，需要重新登录"
    echo "VERIFY_FAILED: state_too_small" > "$STATUS_FILE"
    exit 1
fi

# ============================================================
# 2. 加载状态并打开购买页
# ============================================================
log "加载浏览器状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
sleep 2

log "打开购买页: ${BUY_PAGE}"
agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

# ============================================================
# 3. 检查登录和页面状态
# ============================================================
CURRENT_URL=$(agent-browser get url 2>&1)
PAGE_TITLE=$(agent-browser get title 2>&1 | tr -d '"')
log "URL: $CURRENT_URL"
log "标题: $PAGE_TITLE"

SCREENSHOT_FILE="$SCREENSHOT_DIR/verify_$(date +%Y%m%d_%H%M%S).png"
agent-browser screenshot "$SCREENSHOT_FILE" 2>&1 | tee -a "$LOG_FILE"

SNAP=$(agent-browser snapshot -i 2>&1)

# 检查登录
if echo "$SNAP" | grep -q "zhangyuan"; then
    log "✓ 已登录 (zhangyuanzhuo)"
else
    log "✗ 未检测到登录用户名"
    ERRORS=$((ERRORS + 1))
fi

# 检查购买页
if echo "$SNAP" | grep -qi "coding.plan\|subscribe\|model studio"; then
    log "✓ 购买页正常"
else
    log "✗ 购买页异常"
    ERRORS=$((ERRORS + 1))
fi

# 检查库存
if echo "$SNAP" | grep -qi "out of stock\|售罄\|暂时\|restock"; then
    RESTOCK=$(echo "$SNAP" | grep -i "restock\|售罄\|out of stock" | head -2)
    log "库存: 售罄 - $RESTOCK"
elif echo "$SNAP" | grep -qi "subscribe"; then
    log "!!! 库存: 有货！Subscribe可见！"
    echo "VERIFY_OK: IN_STOCK" > "$STATUS_FILE"
else
    log "? 无法确定库存"
    ERRORS=$((ERRORS + 1))
fi

# 测试eval是否可用（v4依赖eval注入JS）
EVAL_TEST=$(agent-browser eval 'document.title' 2>&1 | head -1)
log "eval测试: $EVAL_TEST"
if [ -z "$EVAL_TEST" ] || echo "$EVAL_TEST" | grep -qi "null\|error\|undefined"; then
    log "✗ eval不可用！v4脚本无法工作"
    ERRORS=$((ERRORS + 1))
else
    log "✓ eval正常"
fi

# ============================================================
# 4. 保存并安全关闭
# ============================================================
log "保存浏览器状态..."
agent-browser state save "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"

# 读取保存后的大小
SAVED_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
log "保存后state: $(du -h "$BROWSER_STATE" | cut -f1) ($SAVED_SIZE bytes)"

if [ "$SAVED_SIZE" -lt 100000 ]; then
    log "WARNING: 保存的state太小，恢复备份"
    cp "$BROWSER_STATE_BACKUP" "$BROWSER_STATE"
    SAVED_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
fi

# 关闭浏览器（这可能覆盖state文件）
agent-browser close 2>&1 > /dev/null
sleep 1

# 关键：关闭后再次检查state，如果被破坏就恢复备份
POST_CLOSE_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
if [ "$POST_CLOSE_SIZE" -lt 100000 ]; then
    log "WARNING: close操作破坏了state(${POST_CLOSE_SIZE}B)，恢复备份"
    cp "$BROWSER_STATE_BACKUP" "$BROWSER_STATE"
    log "已从备份恢复"
fi

FINAL_SIZE=$(du -h "$BROWSER_STATE" | cut -f1)
log "最终 browser_state: $FINAL_SIZE"

# ============================================================
# 5. 汇总
# ============================================================
log "=== 验证完成 | 错误: $ERRORS ==="

if [ $ERRORS -eq 0 ]; then
    echo "VERIFY_OK" > "$STATUS_FILE"
    log "一切正常 ✓"
elif [ "$(cat "$STATUS_FILE" 2>/dev/null)" = "VERIFY_OK: IN_STOCK" ]; then
    log "有货！应立即启动抢购"
else
    echo "VERIFY_WARN: ${ERRORS}_issues" > "$STATUS_FILE"
    log "存在${ERRORS}个问题"
fi
