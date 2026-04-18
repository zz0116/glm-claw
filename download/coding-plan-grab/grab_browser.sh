#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 浏览器自动化抢购脚本
# 补货时间: 2026-04-18 09:30 北京时间
# 策略: 09:28 开始，每3秒刷新页面，检测"去购买"按钮可用性
# ============================================================

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/browser_grab_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
PAGE_URL="https://bailian.console.aliyun.com/cn-beijing?tab=coding-plan#/efm/coding-plan-index"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 阿里百炼 Coding Plan 浏览器自动化抢购脚本启动 ==="

# 检查 browser state 文件
if [ ! -f "$BROWSER_STATE" ]; then
    log "ERROR: 浏览器状态文件不存在: $BROWSER_STATE"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi
log "浏览器状态文件存在 ($(du -h "$BROWSER_STATE" | cut -f1))"

# 加载浏览器状态
log "加载浏览器登录状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"

# 打开购买页面
log "打开百炼 Coding Plan 页面..."
agent-browser open "$PAGE_URL" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

# 切换到概览 tab
log "切换到概览 tab..."
agent-browser snapshot -i 2>&1 | head -20 | tee -a "$LOG_FILE"

MAX_ROUNDS=400  # 最多运行400轮 (约20分钟，3秒/轮)
INTERVAL=3     # 3秒间隔

log "开始抢购监控，间隔 ${INTERVAL}s，最多 ${MAX_ROUNDS} 轮"

for ((i=1; i<=MAX_ROUNDS; i++)); do
    # 每隔20轮打印一次进度
    if (( i % 20 == 0 )); then
        log "第 ${i}/${MAX_ROUNDS} 轮..."
    fi
    
    # 刷新页面获取最新状态
    agent-browser reload 2>&1 > /dev/null
    sleep 3
    
    # 获取页面快照，查找购买按钮
    snapshot_output=$(agent-browser snapshot -i 2>&1)
    
    # 检查是否有"去购买"按钮且不是 disabled
    if echo "$snapshot_output" | grep -q '去购买.*\[ref=e[0-9]*\]' && ! echo "$snapshot_output" | grep -q '去购买.*disabled'; then
        log "!!! 发现可购买的'去购买'按钮 !!!"
        
        # 获取"去购买"按钮的 ref
        buy_ref=$(echo "$snapshot_output" | grep '去购买' | grep -oP '\[ref=\K[^\]]+' | head -1)
        
        if [ -n "$buy_ref" ]; then
            log "点击购买按钮 @$buy_ref"
            agent-browser click "@$buy_ref" 2>&1 | tee -a "$LOG_FILE"
            
            # 等待页面跳转
            sleep 3
            agent-browser wait --load networkidle 2>&1 > /dev/null || true
            sleep 2
            
            # 检查是否跳转到购买页面
            current_url=$(agent-browser get url 2>&1)
            log "当前页面: $current_url"
            
            # 截图保存
            screenshot_file="/home/z/my-project/download/coding-plan-grab/buy_page_$(date +%Y%m%d_%H%M%S).png"
            agent-browser screenshot "$screenshot_file" 2>&1 | tee -a "$LOG_FILE"
            log "截图已保存: $screenshot_file"
            
            # 尝试查找"立即购买"或"提交订单"按钮
            new_snapshot=$(agent-browser snapshot -i 2>&1)
            
            # 查找并点击确认购买按钮
            for btn_text in "立即购买" "确认订单" "提交订单" "去支付" "立即支付" "确认支付"; do
                btn_ref=$(echo "$new_snapshot" | grep "$btn_text" | grep -oP '\[ref=\K[^\]]+' | head -1)
                if [ -n "$btn_ref" ]; then
                    log "发现'$btn_text'按钮 @$btn_ref"
                    agent-browser click "@$btn_ref" 2>&1 | tee -a "$LOG_FILE"
                    sleep 3
                    agent-browser wait --load networkidle 2>&1 > /dev/null || true
                    sleep 2
                    
                    # 再次截图
                    agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/confirm_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                    
                    # 检查新页面
                    confirm_snapshot=$(agent-browser snapshot -i 2>&1)
                    
                    # 查找支付确认按钮
                    pay_ref=$(echo "$confirm_snapshot" | grep -E "支付|确认|pay" | grep -oP '\[ref=\K[^\]]+' | head -1)
                    if [ -n "$pay_ref" ]; then
                        log "发现支付确认按钮 @$pay_ref"
                        agent-browser click "@$pay_ref" 2>&1 | tee -a "$LOG_FILE"
                        sleep 5
                        agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/final_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                    fi
                fi
            done
            
            log "========== 购买流程已触发！=========="
            echo "SUCCESS: browser_purchase_triggered" > "$STATUS_FILE"
            agent-browser close 2>&1 > /dev/null
            exit 0
        fi
    fi
    
    # 也检查"暂时售罄"是否已消失
    if ! echo "$snapshot_output" | grep -q '暂时售罄'; then
        log "!!! '暂时售罄'标记已消失，可能已补货 !!!"
        # 继续循环检测按钮
    fi
    
    # 检查是否已有购买结果
    if [ -f "$STATUS_FILE" ]; then
        status=$(cat "$STATUS_FILE")
        if [[ "$status" == SUCCESS* ]]; then
            log "已标记为成功，退出"
            agent-browser close 2>&1 > /dev/null
            exit 0
        fi
    fi
done

log "抢购脚本执行完毕，共 ${MAX_ROUNDS} 轮"
echo "TIMEOUT: rounds exhausted" > "$STATUS_FILE"
agent-browser close 2>&1 > /dev/null
