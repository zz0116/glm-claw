#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan - 浏览器自动化验证脚本
# 在抢购前运行，验证登录状态和页面可达性
# ============================================================

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/verify_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
PAGE_URL="https://bailian.console.aliyun.com/cn-beijing?tab=coding-plan#/efm/coding-plan-index"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 阿里百炼 Coding Plan 预验证启动 ==="
ERRORS=0

# 1. 检查浏览器状态文件
if [ ! -f "$BROWSER_STATE" ]; then
    log "ERROR: 浏览器状态文件不存在！需要重新登录"
    echo "VERIFY_FAILED: no browser state" > "$STATUS_FILE"
    exit 1
fi
log "浏览器状态文件存在 ($(du -h "$BROWSER_STATE" | cut -f1))"

# 2. 加载状态并打开页面
log "加载浏览器登录状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"

log "打开 Coding Plan 页面..."
agent-browser open "$PAGE_URL" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

# 3. 检查页面是否正确加载
page_title=$(agent-browser get title 2>&1)
log "页面标题: $page_title"

if echo "$page_title" | grep -qi "bailian\|百炼\|model studio"; then
    log "页面加载: 成功"
else
    log "WARNING: 页面标题异常"
    ERRORS=$((ERRORS + 1))
fi

# 4. 检查登录状态
snapshot=$(agent-browser snapshot -i 2>&1)
if echo "$snapshot" | grep -q "zhangyuanzhuo"; then
    log "登录状态: 已登录 (zhangyuanzhuo)"
else
    log "WARNING: 未检测到登录用户名"
    ERRORS=$((ERRORS + 1))
fi

# 5. 检查当前售卖状态
if echo "$snapshot" | grep -q "暂时售罄"; then
    log "售卖状态: 暂时售罄（符合预期，等待09:30补货）"
elif echo "$snapshot" | grep -q "去购买"; then
    log "!!! 售卖状态: 有货！可以立即购买！"
    echo "VERIFY_OK: IN_STOCK" > "$STATUS_FILE"
else
    log "WARNING: 无法确定售卖状态"
    ERRORS=$((ERRORS + 1))
fi

# 6. 截图保存当前页面状态
screenshot_file="/home/z/my-project/download/coding-plan-grab/verify_$(date +%Y%m%d_%H%M%S).png"
agent-browser screenshot "$screenshot_file" 2>&1 | tee -a "$LOG_FILE"
log "验证截图已保存: $screenshot_file"

# 关闭浏览器
agent-browser close 2>&1 > /dev/null

# 汇总
log "=== 验证完成 ==="
log "错误数: $ERRORS"

if [ $ERRORS -eq 0 ]; then
    log "一切正常，等待抢购时间！"
    echo "VERIFY_OK" > "$STATUS_FILE"
else
    log "存在 $ERRORS 个问题，建议手动检查"
    echo "VERIFY_WARN: $ERRORS issues" > "$STATUS_FILE"
fi
