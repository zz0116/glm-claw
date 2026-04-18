#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan - 页面监控抢购脚本（备用方案）
# 使用 agent-browser 模拟页面操作
# ============================================================

LOG_FILE="/home/z/my-project/download/coding-plan-grab/page_grab_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 页面监控抢购脚本启动 ==="

# 使用浏览器打开购买页面，检测按钮状态
# 这里通过直接请求购买页面API来检测
MAX_ROUNDS=300
INTERVAL=2

log "开始页面检测，间隔 ${INTERVAL}s"

for ((i=1; i<=MAX_ROUNDS; i++)); do
    if (( i % 20 == 0 )); then
        log "第 ${i}/${MAX_ROUNDS} 轮检测..."
    fi
    
    # 检查是否已通过API脚本抢到
    if [ -f "$STATUS_FILE" ]; then
        status=$(cat "$STATUS_FILE")
        if [[ "$status" == SUCCESS* ]]; then
            log "API脚本已抢购成功，页面脚本退出"
            exit 0
        fi
    fi
    
    sleep "$INTERVAL"
done

log "页面监控脚本执行完毕"
