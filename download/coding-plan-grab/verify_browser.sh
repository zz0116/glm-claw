#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan - 预验证脚本 v2
# 
# 改进：不再关闭浏览器！避免 browser_state 被覆盖为空
# 改为：打开页面 → 检查状态 → save state → 关闭
# ============================================================

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
BROWSER_STATE_BACKUP="/home/z/my-project/download/coding-plan-grab/browser_state_backup.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/verify_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
PAGE_URL="https://common-buy.aliyun.com/?commodityCode=sfm_platform_public_cn"
PAGE_URL_ALT="https://common-buy.aliyun.com/coding-plan"
SCREENSHOT_DIR="/home/z/my-project/download/coding-plan-grab"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 阿里百炼 Coding Plan 预验证 v2 启动 ==="
ERRORS=0

# ============================================================
# 1. 备份现有 browser_state
# ============================================================
if [ -f "$BROWSER_STATE" ]; then
    STATE_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
    log "现有 browser_state: $(du -h "$BROWSER_STATE" | cut -f1) ($STATE_SIZE bytes)"
    
    # 备份
    cp "$BROWSER_STATE" "$BROWSER_STATE_BACKUP"
    log "已备份到 browser_state_backup.json"
    
    if [ "$STATE_SIZE" -lt 100000 ]; then
        log "WARNING: browser_state 太小，可能已失效"
        ERRORS=$((ERRORS + 1))
    fi
else
    log "ERROR: browser_state.json 不存在！"
    echo "VERIFY_FAILED: no browser state" > "$STATUS_FILE"
    exit 1
fi

# ============================================================
# 2. 加载状态并打开购买页
# ============================================================
log "加载浏览器状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
sleep 2

log "打开购买页..."
agent-browser open "$PAGE_URL" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

# 检查URL
CURRENT_URL=$(agent-browser get url 2>/dev/null)
log "当前URL: $CURRENT_URL"

if ! echo "$CURRENT_URL" | grep -q "common-buy"; then
    log "尝试备用URL..."
    agent-browser open "$PAGE_URL_ALT" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
    sleep 5
    CURRENT_URL=$(agent-browser get url 2>/dev/null)
    log "当前URL: $CURRENT_URL"
fi

# ============================================================
# 3. 检查登录状态和页面内容
# ============================================================
page_title=$(agent-browser get title 2>&1)
log "页面标题: $page_title"

# 截图
SCREENSHOT_FILE="$SCREENSHOT_DIR/verify_$(date +%Y%m%d_%H%M%S).png"
agent-browser screenshot "$SCREENSHOT_FILE" 2>&1 | tee -a "$LOG_FILE"
log "截图: $SCREENSHOT_FILE"

# 检查快照
SNAP=$(agent-browser snapshot -i 2>&1)

# 检查登录
if echo "$SNAP" | grep -q "zhangyuan"; then
    log "✓ 已登录 (zhangyuanzhuo)"
else
    log "WARNING: 未检测到登录用户名"
    ERRORS=$((ERRORS + 1))
fi

# 检查是否在购买页
if echo "$SNAP" | grep -qi "coding.plan\|subscribe\|model studio"; then
    log "✓ 购买页加载成功"
else
    log "WARNING: 购买页内容异常"
    ERRORS=$((ERRORS + 1))
fi

# 检查库存状态
if echo "$SNAP" | grep -qi "out of stock\|售罄\|暂时售罄\|restock"; then
    RESTOCK_TEXT=$(echo "$SNAP" | grep -i "restock\|售罄\|out of stock" | head -3)
    log "库存状态: 售罄 - $RESTOCK_TEXT"
elif echo "$SNAP" | grep -qi "subscribe"; then
    log "!!! 库存状态: 有货！Subscribe按钮可见！"
    echo "VERIFY_OK: IN_STOCK" > "$STATUS_FILE"
    ERRORS=$((ERRORS + 1))  # 标记为警告，抢购脚本应该立即启动
else
    log "WARNING: 无法确定库存状态"
    log "快照关键内容:"
    echo "$SNAP" | head -30 | tee -a "$LOG_FILE"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# 4. 关键：保存当前 browser_state（可能已更新session）
# ============================================================
log "保存当前浏览器状态（刷新session）..."
agent-browser state save "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"

NEW_STATE_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
log "新 browser_state: $(du -h "$BROWSER_STATE" | cut -f1) ($NEW_STATE_SIZE bytes)"

# 如果新 state 太小，恢复备份
if [ "$NEW_STATE_SIZE" -lt 100000 ] && [ "$STATE_SIZE" -ge 100000 ]; then
    log "WARNING: 新state太小，恢复备份"
    cp "$BROWSER_STATE_BACKUP" "$BROWSER_STATE"
fi

# 现在可以安全关闭浏览器
agent-browser close 2>&1 > /dev/null

# ============================================================
# 5. 汇总
# ============================================================
log "=== 验证完成 ==="
log "错误数: $ERRORS"
log "browser_state 已保存并验证"

if [ $ERRORS -eq 0 ]; then
    log "一切正常，等待抢购！"
    echo "VERIFY_OK" > "$STATUS_FILE"
else
    log "存在 $ERRORS 个问题，请查看日志"
    echo "VERIFY_WARN: $ERRORS issues" > "$STATUS_FILE"
fi
