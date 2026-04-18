#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 极速抢购脚本 v4.1
# 
# 核心策略：浏览器内JS 50ms轮询 + shell智能reload
# 
# v4.1 改进（相比v4）：
#   - JS不再自己reload（会销毁JS），由shell统一管理
#   - shell根据距补货时间动态调整reload频率
#   - 临近补货时间时加速reload（30s→5s→1s）
#   - reload后自动重新注入JS
#   - 去掉 set -e 防止意外退出
# ============================================================

set -uo pipefail

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_DIR="/home/z/my-project/download/coding-plan-grab"
LOG_FILE="${LOG_DIR}/turbo_v4_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="${LOG_DIR}/purchase_status.txt"
BUY_PAGE="https://common-buy.aliyun.com/coding-plan"
# GitHub push 由 cron 任务中的 agent 处理，不在脚本中硬编码token

# 补货时间（北京时间，精确到秒）
RESTOCK_TIME="09:30:00"
RESTOCK_EPOCH=$(date -d "$(date +%Y-%m-%d) $RESTOCK_TIME" +%s 2>/dev/null || echo 0)

# 如果当前已过补货时间，设为明天
if [ "$RESTOCK_EPOCH" -le "$(date +%s)" ]; then
    RESTOCK_EPOCH=$((RESTOCK_EPOCH + 86400))
    log "补货时间已过，设为明天: $(date -d @$RESTOCK_EPOCH '+%Y-%m-%d %H:%M:%S')"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

cleanup() {
    local st=$(cat "$STATUS_FILE" 2>/dev/null || echo "unknown")
    log "退出，最终状态: $st"
}
trap cleanup EXIT

# ============================================================
# 核心JS：纯监控+点击，不含reload逻辑
# ============================================================
TURBO_JS='(function(){
    window.__v4 = {
        started: true,
        phase: "monitoring",
        clicked: false,
        purchaseDone: false,
        payDone: false,
        clickTime: null,
        logs: [],
        startTime: Date.now(),
        btnText: "",
        btnDisabled: true
    };
    var R = window.__v4;
    function log(msg) {
        var ms = Date.now() - R.startTime;
        R.logs.push("[" + ms + "ms] " + msg);
        if (R.logs.length > 300) R.logs.shift();
    }
    log("v4.1 monitor started");

    function findBtn() {
        var btns = document.querySelectorAll("button");
        for (var i = 0; i < btns.length; i++) {
            var b = btns[i];
            var rect = b.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            var t = (b.textContent || "").trim();
            if (t.indexOf("Subscribe") !== -1 || t.indexOf("out of stock") !== -1 ||
                t.indexOf("订阅") !== -1 || t.indexOf("购买") !== -1 || t.indexOf("一次性") !== -1) {
                var dis = b.disabled || b.getAttribute("disabled") !== null;
                R.btnText = t.substring(0, 60);
                R.btnDisabled = dis;
                return { el: b, text: t, disabled: dis };
            }
        }
        return null;
    }

    function onButtonEnabled(btn) {
        log("!!! BUTTON ENABLED !!! text=" + btn.text);
        try { btn.el.click(); } catch(e) {
            log("click error: " + e.message);
            try { btn.el.dispatchEvent(new MouseEvent("click", {bubbles:true,cancelable:true})); } catch(e2) {}
        }
        R.clicked = true;
        R.clickTime = Date.now();
        R.phase = "clicked_subscribe";
        log("CLICKED! elapsed=" + (Date.now() - R.startTime) + "ms");
        clearInterval(iv);
        try { obs.disconnect(); } catch(e) {}
        handleAfterClick();
    }

    function handleAfterClick() {
        log("Waiting for page transition...");
        var cnt = 0;
        var piv = setInterval(function() {
            cnt++;
            var url = window.location.href;
            // 到了支付/订单页
            if (url.indexOf("cashier") !== -1 || url.indexOf("pay") !== -1 ||
                url.indexOf("order") !== -1 || url.indexOf("success") !== -1 ||
                url.indexOf("trade") !== -1) {
                log("Payment page detected: " + url);
                R.phase = "payment_page";
                clearInterval(piv);
                setTimeout(function() {
                    // 选余额支付
                    var lbls = document.querySelectorAll("label,div,span");
                    for (var i=0;i<lbls.length;i++) {
                        var lt = lbls[i].textContent || "";
                        if (lt.indexOf("余额") !== -1 && lt.indexOf("支付宝") === -1) {
                            lbls[i].click(); break;
                        }
                    }
                    // 点击支付
                    var pbs = document.querySelectorAll("button,a,[role=button],input[type=submit]");
                    var pks = ["确认支付","去支付","立即支付","确认付款","Pay","Confirm","Submit"];
                    for (var j=0;j<pbs.length;j++) {
                        var pb = pbs[j]; if(pb.disabled) continue;
                        var pt = (pb.textContent||pb.value||"").trim();
                        for (var k=0;k<pks.length;k++) {
                            if (pt.indexOf(pks[k]) !== -1) {
                                pb.click(); R.payDone = true; R.phase = "payment_done";
                                log("Pay clicked: " + pt); return;
                            }
                        }
                    }
                }, 500);
                return;
            }
            // 检查确认按钮
            var abs = document.querySelectorAll("button,a,[role=button],input[type=submit]");
            var cks = ["确认","提交","Confirm","Submit","创建订单","下一步"];
            for (var i=0;i<abs.length;i++) {
                var ab = abs[i]; if(ab.disabled||ab.style.display==="none") continue;
                var at = (ab.textContent||ab.value||"").trim();
                if (ab.getBoundingClientRect().width === 0) continue;
                for (var j=0;j<cks.length;j++) {
                    if (at.indexOf(cks[j]) !== -1 && at.length < 20) {
                        ab.click(); R.purchaseDone = true; R.phase = "confirmed";
                        log("Confirm clicked: " + at); clearInterval(piv); return;
                    }
                }
            }
            if (cnt > 60) { clearInterval(piv); log("Post-click timeout"); }
        }, 500);
    }

    // MutationObserver
    var obs = new MutationObserver(function() {
        if (R.clicked) return;
        var r = findBtn();
        if (r && !r.disabled) onButtonEnabled(r);
    });
    try { obs.observe(document.body, {childList:true,subtree:true,attributes:true,
        attributeFilter:["class","disabled","style","aria-disabled"]}); } catch(e) {}

    // 50ms轮询
    var iv = setInterval(function() {
        if (R.clicked) { clearInterval(iv); return; }
        var r = findBtn();
        if (r && !r.disabled) onButtonEnabled(r);
    }, 50);

    setTimeout(function() { clearInterval(iv); try{obs.disconnect();}catch(e){}
        if(!R.clicked) { R.phase="timeout"; log("Timeout 20min"); } }, 1200000);

    return "v4_injected";
})()'

# ============================================================
# 注入JS的函数
# ============================================================
inject_js() {
    local result
    result=$(agent-browser eval "$TURBO_JS" 2>&1 | head -1)
    echo "$result"
}

# ============================================================
# 获取JS状态的函数（安全，不会因错误退出）
# ============================================================
get_js_status() {
    agent-browser eval 'JSON.stringify(window.__v4 || {error:"lost"})' 2>/dev/null | head -1 || echo '{"error":"eval_failed"}'
}

# ============================================================
# 主流程
# ============================================================
log "========================================"
log "=== 阿里百炼 Coding Plan 极速抢购 v4.1 ==="
log "========================================"
echo "RUNNING" > "$STATUS_FILE"

if [ ! -f "$BROWSER_STATE" ]; then
    log "FATAL: browser_state.json 不存在"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi

STATE_SIZE=$(du -h "$BROWSER_STATE" | cut -f1)
log "browser_state: $STATE_SIZE"

if [ "$STATE_SIZE" = "4.0K" ]; then
    log "FATAL: state为空(4K)，需要重新登录"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi

# Step 1: 加载浏览器
log "加载浏览器状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
sleep 2

# Step 2: 打开购买页
log "打开购买页: ${BUY_PAGE}"
agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

PAGE_TITLE=$(agent-browser get title 2>&1 | tr -d '"' | head -1)
log "页面标题: $PAGE_TITLE"

if [ "$PAGE_TITLE" != "Coding Plan" ]; then
    log "标题异常，重试..."
    agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
    sleep 8
fi

agent-browser screenshot "${LOG_DIR}/v4_start_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

# Step 3: 注入JS
log "注入抢购JS..."
INJECT=$(inject_js)
log "注入结果: $INJECT"

sleep 1
INIT_STATUS=$(get_js_status)
log "初始状态: $INIT_STATUS"

if echo "$INIT_STATUS" | grep -q "lost\|error"; then
    log "WARNING: JS可能未成功注入，5秒后重试..."
    sleep 5
    INJECT=$(inject_js)
    log "重试: $INJECT"
fi

# Step 4: 智能监控循环
log "========================================"
log "进入智能监控模式"
log "JS在浏览器内50ms轮询 | shell负责reload+重注入"
log "补货目标时间: ${RESTOCK_TIME}"
log "========================================"

LAST_RELOAD=0
ROUND=0
MAX_ROUNDS=420  # 35分钟 (每5秒一轮)
CLICK_ATTEMPTED=false

while [ $ROUND -lt $MAX_ROUNDS ]; do
    ROUND=$((ROUND + 1))
    NOW=$(date +%s)
    NOW_TIME=$(date +%H:%M:%S)

    # ===== 动态reload间隔（参考小红书攻略优化）=====
    SECONDS_TO_RESTOCK=$((RESTOCK_EPOCH - NOW))

    if [ "$SECONDS_TO_RESTOCK" -gt 600 ]; then
        # 距补货 > 10分钟: 每20秒reload（减少请求，避免被封）
        RELOAD_INTERVAL=20
    elif [ "$SECONDS_TO_RESTOCK" -gt 120 ]; then
        # 距补货 2-10分钟: 每10秒reload
        RELOAD_INTERVAL=10
    elif [ "$SECONDS_TO_RESTOCK" -gt 30 ]; then
        # 距补货 30秒-2分钟: 每3秒reload
        RELOAD_INTERVAL=3
    elif [ "$SECONDS_TO_RESTOCK" -gt -10 ]; then
        # 距补货 -10到30秒: 每0.8秒reload（最高频率！）
        RELOAD_INTERVAL=1
    else
        # 已过补货时间10秒+: 每3秒reload
        RELOAD_INTERVAL=3
    fi

    SECONDS_SINCE_RELOAD=$((NOW - LAST_RELOAD))

    # ===== 需要reload? =====
    NEED_RELOAD=false
    if [ "$SECONDS_SINCE_RELOAD" -ge "$RELOAD_INTERVAL" ]; then
        NEED_RELOAD=true
    fi

    # ===== 获取JS状态 =====
    JS_RESULT=$(get_js_status)

    # 检查JS是否存活
    if echo "$JS_RESULT" | grep -q "lost\|error.*eval"; then
        log "JS丢失，需要reload+重注入"
        NEED_RELOAD=true
    fi

    # ===== 执行reload =====
    if [ "$NEED_RELOAD" = true ]; then
        LAST_RELOAD=$NOW
        log "Reload | round=$ROUND time=$NOW_TIME to_restock=${SECONDS_TO_RESTOCK}s interval=${RELOAD_INTERVAL}s"

        agent-browser reload 2>&1 > /dev/null
        sleep 2

        # 重注入JS
        INJECT=$(inject_js)
        if echo "$INJECT" | grep -q "v4_injected"; then
            log "重注入成功 ✓"
        else
            log "重注入失败: $INJECT，等待下次尝试"
        fi

        sleep 1
        JS_RESULT=$(get_js_status)
    fi

    # ===== 解析JS状态 =====
    CLICKED=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('clicked',False))" 2>/dev/null || echo "False")
    PHASE=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('phase','?'))" 2>/dev/null || echo "?")
    BTN_TEXT=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btnText','?'))" 2>/dev/null || echo "?")
    RELOADS_JS=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reloadCount',0))" 2>/dev/null || echo "0")

    # ===== 点击成功处理 =====
    if [ "$CLICKED" = "True" ]; then
        log "========================================"
        log "!!! Subscribe 已被JS点击 !!!"
        log "========================================"

        agent-browser screenshot "${LOG_DIR}/v4_clicked_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

        # 打印JS日志
        JS_LOGS=$(echo "$JS_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for l in d.get('logs',[])[-15:]:
    print(l)
" 2>/dev/null)
        log "JS日志:"
        echo "$JS_LOGS" | tee -a "$LOG_FILE"

        # 等待后续页面
        log "等待页面跳转..."
        for ((j=1; j<=20; j++)); do
            sleep 3

            CUR_URL=$(agent-browser get url 2>&1)
            PHASE_NOW=$(agent-browser eval 'window.__v4?window.__v4.phase:"?"' 2>&1 | head -1 | tr -d '"')
            PAY_DONE=$(agent-browser eval 'window.__v4?window.__v4.payDone:false' 2>&1 | head -1 | tr -d '"')

            log "后续 [$j/20] phase=$PHASE_NOW pay=$PAY_DONE url=${CUR_URL:0:60}"

            if [ "$PAY_DONE" = "true" ] || [ "$PHASE_NOW" = "payment_done" ]; then
                log "!!! 支付完成 !!!"
                agent-browser screenshot "${LOG_DIR}/v4_success_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                echo "SUCCESS: subscribe_and_pay_done" > "$STATUS_FILE"
                agent-browser close 2>&1 > /dev/null
                exit 0
            fi

            if [ "$PHASE_NOW" = "confirmed" ]; then
                log "!!! 订单已确认 !!!"
                agent-browser screenshot "${LOG_DIR}/v4_confirmed_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                echo "SUCCESS: order_confirmed" > "$STATUS_FILE"
                agent-browser close 2>&1 > /dev/null
                exit 0
            fi

            if echo "$CUR_URL" | grep -q "cashier\|pay\|order\|success\|trade"; then
                log "检测到支付页面"
                agent-browser screenshot "${LOG_DIR}/v4_paypage_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                for pkw in "确认支付" "去支付" "立即支付" "Pay" "Confirm"; do
                    pc=$(agent-browser click "$pkw" 2>&1)
                    if ! echo "$pc" | grep -qi "fail\|error\|not found"; then
                        log "支付按钮点击: $pkw"
                        sleep 3
                        agent-browser screenshot "${LOG_DIR}/v4_paydone_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                        echo "SUCCESS: pay_clicked" > "$STATUS_FILE"
                        break
                    fi
                done
                echo "SUCCESS: subscribe_clicked" > "$STATUS_FILE"
                agent-browser close 2>&1 > /dev/null
                exit 0
            fi
        done

        log "后续超时，但Subscribe已点击"
        echo "SUCCESS: subscribe_clicked" > "$STATUS_FILE"
        agent-browser close 2>&1 > /dev/null
        exit 0
    fi

    # ===== 超时检测 =====
    if [ "$PHASE" = "timeout" ]; then
        log "JS报告超时"
        break
    fi

    # ===== 进度日志 =====
    if [ $((ROUND % 6)) -eq 0 ]; then
        log "[$ROUND/$MAX_ROUNDS] time=$NOW_TIME restock_in=${SECONDS_TO_RESTOCK}s btn=$BTN_TEXT"
    fi

    # ===== shell层兜底：临近补货时间用 agent-browser click =====
    # JS丢失或reload间隙时，shell直接尝试点击（图片来源攻略启发）
    if [ "$CLICK_ATTEMPTED" = "false" ] && [ "$SECONDS_TO_RESTOCK" -lt 30 ] && [ "$SECONDS_TO_RESTOCK" -gt -60 ]; then
        if [ $((ROUND % 3)) -eq 0 ]; then
            CLICK_TRY=$(agent-browser click "Subscribe" 2>&1)
            if ! echo "$CLICK_TRY" | grep -qi "fail\|error\|disabled\|not found"; then
                log "Shell兜底点击成功! $CLICK_TRY"
                CLICK_ATTEMPTED=true
            fi
        fi
    fi

    sleep 5
done

# ============================================================
# 超时退出
# ============================================================
log "脚本执行完毕（超时或按钮未变为可用）"
agent-browser screenshot "${LOG_DIR}/v4_timeout_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
echo "TIMEOUT: v4.1_exhausted" > "$STATUS_FILE"
agent-browser close 2>&1 > /dev/null
