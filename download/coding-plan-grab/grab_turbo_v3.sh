#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 极速抢购脚本 v3
# 核心策略：直接在购买页 waiting，agent-browser click 疯狂轮询
# 
# v2.1教训：
#   1. JS注入在SPA返回null → 改用 agent-browser 原生指令
#   2. 从控制台跳转购买页浪费5-8秒 → 直接打开购买页
#   3. 09:30才启动太晚 → 09:25就打开页面等着
# ============================================================

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/turbo_v3_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
BUY_PAGE="https://common-buy.aliyun.com/coding-plan"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

# ============================================================
# 点击后处理函数
# ============================================================
handle_post_click() {
    log "========== 点击后处理 =========="
    
    agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/v3_post_click_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
    
    local current_url
    current_url=$(agent-browser get url 2>&1)
    log "当前URL: $current_url"
    
    # 如果跳转到支付/订单页面
    if echo "$current_url" | grep -q "cashier\|pay\|payment\|order\|success"; then
        log "!!! 已跳转到支付/订单页面！"
        agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/v3_pay_page_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
        
        # 尝试点击支付确认按钮
        for pay_kw in "确认支付" "去支付" "立即支付" "确认付款" "余额支付" "Confirm" "Pay"; do
            local pay_result
            pay_result=$(agent-browser click "$pay_kw" 2>&1)
            if ! echo "$pay_result" | grep -qi "fail\|error\|unknown"; then
                log "支付按钮已点击: $pay_kw"
                sleep 3
                agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/v3_pay_confirm_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                break
            fi
        done
        
        echo "SUCCESS: purchase_and_pay_triggered" > "$STATUS_FILE"
        agent-browser close 2>&1 > /dev/null
        return 0
    fi
    
    # 没跳转到支付页，检查是否弹出了确认框或其他按钮
    sleep 2
    local snapshot
    snapshot=$(agent-browser snapshot -i 2>&1)
    
    for btn in "Confirm" "Submit" "确认" "提交" "立即购买" "创建订单" "Next" "下一步"; do
        local btn_ref
        btn_ref=$(echo "$snapshot" | grep -i "$btn" | grep -oP '\[ref=\K[^\]]+' | head -1)
        if [ -n "$btn_ref" ]; then
            log "发现确认按钮: $btn @$btn_ref"
            agent-browser click "@$btn_ref" 2>&1 | tee -a "$LOG_FILE"
            sleep 3
            agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/v3_confirm_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
            break
        fi
    done
    
    echo "SUCCESS: purchase_triggered" > "$STATUS_FILE"
    agent-browser close 2>&1 > /dev/null
    return 0
}

# ============================================================
# 主流程
# ============================================================
log "=== 阿里百炼 Coding Plan 极速抢购脚本 v3 启动 ==="
echo "RUNNING" > "$STATUS_FILE"

if [ ! -f "$BROWSER_STATE" ]; then
    log "ERROR: 浏览器状态文件不存在"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi
log "浏览器状态文件 ($(du -h "$BROWSER_STATE" | cut -f1))"

# 加载登录状态
log "加载浏览器登录状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
sleep 2

# ============================================================
# 关键改进：直接打开购买确认页，不经过百炼控制台
# ============================================================
log "直接打开购买确认页 $BUY_PAGE ..."
agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

# 验证页面
log "验证购买页加载..."
local_snapshot=$(agent-browser snapshot -i 2>&1)
if echo "$local_snapshot" | grep -qi "subscribe\|coding plan\|coding-plan"; then
    log "购买页加载成功 ✓"
else
    log "WARNING: 购买页加载异常，重新尝试..."
    agent-browser close 2>&1 > /dev/null
    sleep 1
    agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
    sleep 1
    agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
    sleep 8
fi

# 获取初始状态
local_snapshot=$(agent-browser snapshot -i 2>&1)
log "初始状态："
echo "$local_snapshot" | grep -iE "subscribe|button|stock|coupon|balance|售罄" | head -10 | tee -a "$LOG_FILE"
agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/v3_start_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

# 获取 Subscribe 按钮的 ref
SUBSCRIBE_REF=$(echo "$local_snapshot" | grep -i 'Subscribe' | grep -oP '\[ref=\K[^\]]+' | head -1)
log "Subscribe按钮ref: ${SUBSCRIBE_REF:-未找到}"

# ============================================================
# 核心循环：疯狂点击 Subscribe
# 
# - 每0.5秒尝试点击一次
# - disabled时click失败，enabled时成功 → 省去检测时间
# - 每30秒reload一次防止页面过期
# ============================================================
MAX_ROUNDS=1800   # 15分钟
RELOAD_CNT=0
CLICK_OK=false

log "开始疯狂点击模式 (0.5s/次, 最多${MAX_ROUNDS}轮)..."

for ((i=1; i<=MAX_ROUNDS; i++)); do
    RELOAD_CNT=$((RELOAD_CNT + 1))
    
    # ===== 每60轮(30秒)做一次完整刷新 =====
    if (( RELOAD_CNT >= 60 )); then
        RELOAD_CNT=0
        agent-browser reload 2>&1 > /dev/null
        sleep 2
        
        local_snapshot=$(agent-browser snapshot -i 2>&1)
        sub_line=$(echo "$local_snapshot" | grep -i "Subscribe")
        log "刷新 [${i}/${MAX_ROUNDS}]: $sub_line"
        
        # 重新获取ref
        SUBSCRIBE_REF=$(echo "$local_snapshot" | grep -i 'Subscribe' | grep -oP '\[ref=\K[^\]]+' | head -1)
        
        # 如果按钮可用，立即点击
        if echo "$sub_line" | grep -q "Subscribe" && ! echo "$sub_line" | grep -q "disabled"; then
            log "!!! Subscribe按钮已启用！立即点击！"
            if [ -n "$SUBSCRIBE_REF" ]; then
                agent-browser click "@$SUBSCRIBE_REF" 2>&1 | tee -a "$LOG_FILE"
            else
                agent-browser click "Subscribe" 2>&1 | tee -a "$LOG_FILE"
            fi
            handle_post_click
            exit $?
        fi
        continue
    fi
    
    # ===== 快速路径：直接尝试点击（不检测，直接点）=====
    # 用ref点击
    if [ -n "$SUBSCRIBE_REF" ]; then
        click_out=$(agent-browser click "@$SUBSCRIBE_REF" 2>&1)
        if ! echo "$click_out" | grep -qi "fail\|error\|unknown\|disabled\|✗"; then
            log "!!! 点击成功！(ref=$SUBSCRIBE_REF) round=$i"
            handle_post_click
            exit $?
        fi
    fi
    
    # 用文字点击
    click_out=$(agent-browser click "Subscribe" 2>&1)
    if ! echo "$click_out" | grep -qi "fail\|error\|unknown\|disabled\|✗"; then
        log "!!! 点击成功！(text=Subscribe) round=$i"
        SUBSCRIBE_REF=$(agent-browser snapshot -i 2>&1 | grep -i 'Subscribe' | grep -oP '\[ref=\K[^\]]+' | head -1)
        handle_post_click
        exit $?
    fi
    
    # 进度
    if (( i % 20 == 0 )); then
        log "等待中 [${i}/${MAX_ROUNDS}] ref=${SUBSCRIBE_REF:-none}"
    fi
    
    sleep 0.5
done

log "脚本执行完毕，未成功"
echo "TIMEOUT: v3_exhausted" > "$STATUS_FILE"
agent-browser close 2>&1 > /dev/null
