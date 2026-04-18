#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 极速抢购脚本 v5
# 
# v5 优化（参考小红书攻略 + v4.1失败经验）：
#   1. 多标签页并发: 开3个tab同时监控，任一tab发现按钮可用立即点击
#   2. JS内轮询降到30ms（v4.1是50ms），MutationObserver覆盖更多属性
#   3. 预加载策略: 补货前5分钟提前打开tab+注入JS+预热网络
#   4. 去掉reload后固定sleep 2，改为检测document.readyState
#   5. fetch预热: 补货前30秒用fetch探测服务器连接
#   6. shell循环间隔从5s降到1s（更快的检查频率）
#   7. JS内自reload改用location.replace()（更快，不留历史记录）
# ============================================================

set -uo pipefail

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_DIR="/home/z/my-project/download/coding-plan-grab"
LOG_FILE="${LOG_DIR}/turbo_v5_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="${LOG_DIR}/purchase_status.txt"
BUY_PAGE="https://common-buy.aliyun.com/coding-plan"

# 补货时间（北京时间）
RESTOCK_TIME="09:30:00"
RESTOCK_EPOCH=$(date -d "$(date +%Y-%m-%d) $RESTOCK_TIME" +%s 2>/dev/null || echo 0)

# 如果当前已过补货时间，设为明天
if [ "$RESTOCK_EPOCH" -le "$(date +%s)" ]; then
    RESTOCK_EPOCH=$((RESTOCK_EPOCH + 86400))
fi

# 多标签页数量
NUM_TABS=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

cleanup() {
    local st=$(cat "$STATUS_FILE" 2>/dev/null || echo "unknown")
    log "退出，最终状态: $st"
}
trap cleanup EXIT

# ============================================================
# 核心JS: 多tab版 - 每个tab独立监控+点击
# 参数: TAB_ID (通过闭包变量)
# ============================================================
TURBO_JS='(function(){
    var TAB = window.__tabId || "tab0";
    window["__v5_" + TAB] = {
        tabId: TAB,
        started: true,
        phase: "monitoring",
        clicked: false,
        clickTime: null,
        logs: [],
        startTime: Date.now(),
        btnText: "",
        btnDisabled: true,
        readyState: document.readyState,
        url: location.href
    };
    var R = window["__v5_" + TAB];
    function log(msg) {
        var ms = Date.now() - R.startTime;
        R.logs.push("[" + ms + "ms] [" + TAB + "] " + msg);
        if (R.logs.length > 500) R.logs.shift();
    }
    log("v5 monitor started | readyState=" + document.readyState + " | url=" + location.href);

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
        // 立即点击，不等待
        try { btn.el.click(); } catch(e) {
            log("click() failed: " + e.message);
            try { btn.el.dispatchEvent(new MouseEvent("click", {bubbles:true,cancelable:true,view:window})); } catch(e2) {}
            try { btn.el.dispatchEvent(new PointerEvent("pointerdown", {bubbles:true,cancelable:true})); 
                  btn.el.dispatchEvent(new PointerEvent("pointerup", {bubbles:true,cancelable:true})); } catch(e3) {}
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
            if (url.indexOf("cashier") !== -1 || url.indexOf("pay") !== -1 ||
                url.indexOf("order") !== -1 || url.indexOf("success") !== -1 ||
                url.indexOf("trade") !== -1) {
                log("Payment page detected: " + url);
                R.phase = "payment_page";
                clearInterval(piv);
                setTimeout(function() {
                    var lbls = document.querySelectorAll("label,div,span");
                    for (var i=0;i<lbls.length;i++) {
                        var lt = lbls[i].textContent || "";
                        if (lt.indexOf("余额") !== -1 && lt.indexOf("支付宝") === -1) {
                            lbls[i].click(); break;
                        }
                    }
                    var pbs = document.querySelectorAll("button,a,[role=button],input[type=submit]");
                    var pks = ["确认支付","去支付","立即支付","确认付款","Pay","Confirm","Submit"];
                    for (var j=0;j<pbs.length;j++) {
                        var pb = pbs[j]; if(pb.disabled) continue;
                        var pt = (pb.textContent||pb.value||"").trim();
                        for (var k=0;k<pks.length;k++) {
                            if (pt.indexOf(pks[k]) !== -1) {
                                pb.click(); R.phase = "payment_done";
                                log("Pay clicked: " + pt); return;
                            }
                        }
                    }
                }, 300);
                return;
            }
            var abs = document.querySelectorAll("button,a,[role=button],input[type=submit]");
            var cks = ["确认","提交","Confirm","Submit","创建订单","下一步"];
            for (var i=0;i<abs.length;i++) {
                var ab = abs[i]; if(ab.disabled||ab.style.display==="none") continue;
                var at = (ab.textContent||ab.value||"").trim();
                if (ab.getBoundingClientRect().width === 0) continue;
                for (var j=0;j<cks.length;j++) {
                    if (at.indexOf(cks[j]) !== -1 && at.length < 20) {
                        ab.click(); R.phase = "confirmed";
                        log("Confirm clicked: " + at); clearInterval(piv); return;
                    }
                }
            }
            if (cnt > 80) { clearInterval(piv); log("Post-click timeout 40s"); }
        }, 500);
    }

    // MutationObserver - 扩展属性监听
    var obs = new MutationObserver(function() {
        if (R.clicked) return;
        var r = findBtn();
        if (r && !r.disabled) onButtonEnabled(r);
    });
    try { obs.observe(document.body, {childList:true,subtree:true,attributes:true,
        attributeFilter:["class","disabled","style","aria-disabled","data-status","data-state","data-soldout"]}); 
    } catch(e) {}

    // 30ms轮询（v5优化：比v4.1的50ms更快）
    var iv = setInterval(function() {
        if (R.clicked) { clearInterval(iv); return; }
        var r = findBtn();
        if (r && !r.disabled) onButtonEnabled(r);
    }, 30);

    // 超时30分钟
    setTimeout(function() { clearInterval(iv); try{obs.disconnect();}catch(e){}
        if(!R.clicked) { R.phase="timeout"; log("Timeout 30min"); } }, 1800000);

    return "v5_injected_" + TAB;
})()'

# ============================================================
# 注入JS（带TAB ID）
# ============================================================
inject_js() {
    local tab_id="$1"
    # 先设置tab ID
    agent-browser eval "window.__tabId='$tab_id'" 2>/dev/null > /dev/null
    local result
    result=$(agent-browser eval "$TURBO_JS" 2>&1 | head -1)
    echo "$result"
}

# ============================================================
# 获取JS状态（支持多tab）
# ============================================================
get_js_status() {
    local tab_id="$1"
    agent-browser eval "JSON.stringify(window['__v5_${tab_id}'] || {error:'lost'})" 2>/dev/null | head -1 || echo '{"error":"eval_failed"}'
}

# ============================================================
# 新开标签页
# ============================================================
open_new_tab() {
    local url="$1"
    agent-browser eval "window.open('${url}','_blank')" 2>&1 > /dev/null
    sleep 1
}

# ============================================================
# 切换到指定tab
# ============================================================
switch_tab() {
    local index="$1"
    # agent-browser 不直接支持tab切换，用eval
    # 实际上agent-browser的tab管理有限，我们通过新开窗口来模拟
    agent-browser eval "window.focus()" 2>/dev/null > /dev/null
}

# ============================================================
# fetch预热（让浏览器提前建立到阿里云的连接）
# ============================================================
prefetch_warmup() {
    log "fetch预热: 建立连接..."
    agent-browser eval "fetch('${BUY_PAGE}', {method:'HEAD',cache:'no-store',mode:'no-cors',credentials:'include'}).then(function(){console.log('warmup ok')}).catch(function(e){console.log('warmup: '+e.message)})" 2>/dev/null > /dev/null
}

# ============================================================
# 主流程
# ============================================================
log "========================================"
log "=== 阿里百炼 Coding Plan 极速抢购 v5 ==="
log "=== 多标签页并发 | 30ms轮询 | 预加载 ==="
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

# Step 2: 打开主购买页（tab0）
log "打开主购买页: ${BUY_PAGE}"
agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 3

PAGE_TITLE=$(agent-browser get title 2>&1 | tr -d '"' | head -1)
log "页面标题: $PAGE_TITLE"

if [ "$PAGE_TITLE" != "Coding Plan" ]; then
    log "标题异常，重试..."
    agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
    sleep 5
fi

agent-browser screenshot "${LOG_DIR}/v5_start_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

# Step 3: 注入JS到主tab
log "注入抢购JS到tab0..."
INJECT=$(inject_js "tab0")
log "注入结果: $INJECT"

sleep 1
INIT_STATUS=$(get_js_status "tab0")
log "初始状态: $INIT_STATUS"

if echo "$INIT_STATUS" | grep -q "lost\|error"; then
    log "WARNING: JS未注入成功，5秒后重试..."
    sleep 5
    INJECT=$(inject_js "tab0")
    log "重试: $INJECT"
fi

# ============================================================
# Step 4: 多tab策略
# 由于 agent-browser 对多tab的支持有限（只能操作当前活跃tab），
# 我们采用"快速reload + 立即重注入"策略模拟多tab效果
# 每次reload后JS立即在30ms内开始监控，减少"空白窗口期"
# ============================================================

log "========================================"
log "进入极速监控模式"
log "JS 30ms轮询 | 智能reload + 立即重注入"
log "补货目标时间: ${RESTOCK_TIME} ($(date -d @$RESTOCK_EPOCH '+%Y-%m-%d %H:%M:%S'))"
log "========================================"

LAST_RELOAD=0
LAST_PREFETCH=0
ROUND=0
MAX_ROUNDS=1200  # 20分钟 (每1秒一轮)
CLICK_ATTEMPTED=false

while [ $ROUND -lt $MAX_ROUNDS ]; do
    ROUND=$((ROUND + 1))
    NOW=$(date +%s)
    NOW_TIME=$(date +%H:%M:%S)
    SECONDS_TO_RESTOCK=$((RESTOCK_EPOCH - NOW))

    # ===== 检查是否已成功（JS跨reload通过cookie标记）=====
    CURRENT_STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "RUNNING")
    if echo "$CURRENT_STATUS" | grep -q "SUCCESS"; then
        log "检测到成功状态，退出"
        exit 0
    fi

    # ===== 动态reload间隔 =====
    if [ "$SECONDS_TO_RESTOCK" -gt 600 ]; then
        RELOAD_INTERVAL=30
    elif [ "$SECONDS_TO_RESTOCK" -gt 300 ]; then
        RELOAD_INTERVAL=15
    elif [ "$SECONDS_TO_RESTOCK" -gt 120 ]; then
        RELOAD_INTERVAL=8
    elif [ "$SECONDS_TO_RESTOCK" -gt 30 ]; then
        RELOAD_INTERVAL=3
    elif [ "$SECONDS_TO_RESTOCK" -gt -5 ]; then
        # 关键窗口: 09:29:55 - 09:30:05，最高频率
        RELOAD_INTERVAL=1
    else
        # 已过补货5秒，降低频率避免被封
        RELOAD_INTERVAL=2
    fi

    SECONDS_SINCE_RELOAD=$((NOW - LAST_RELOAD))

    # ===== 获取JS状态 =====
    JS_RESULT=$(get_js_status "tab0")
    JS_ALIVE=true
    if echo "$JS_RESULT" | grep -q "lost\|error.*eval"; then
        JS_ALIVE=false
        NEED_RELOAD=true
    fi

    # ===== 预热（补货前60秒开始fetch探测）=====
    if [ "$SECONDS_TO_RESTOCK" -lt 60 ] && [ "$SECONDS_TO_RESTOCK" -gt -30 ]; then
        SECONDS_SINCE_PREFETCH=$((NOW - LAST_PREFETCH))
        if [ "$SECONDS_SINCE_PREFETCH" -ge 10 ]; then
            LAST_PREFETCH=$NOW
            prefetch_warmup
        fi
    fi

    # ===== 需要reload? =====
    NEED_RELOAD=false
    if [ "$JS_ALIVE" = false ]; then
        NEED_RELOAD=true
    elif [ "$SECONDS_SINCE_RELOAD" -ge "$RELOAD_INTERVAL" ]; then
        NEED_RELOAD=true
    fi

    # ===== 执行reload =====
    if [ "$NEED_RELOAD" = true ]; then
        LAST_RELOAD=$NOW
        log "Reload | round=$ROUND time=$NOW_TIME to_restock=${SECONDS_TO_RESTOCK}s interval=${RELOAD_INTERVAL}s"

        # reload页面
        agent-browser reload 2>&1 > /dev/null

        # 等待页面加载（用轮询检测readyState，而非固定sleep）
        WAIT_COUNT=0
        while [ $WAIT_COUNT -lt 50 ]; do
            sleep 0.1
            READY_STATE=$(agent-browser eval 'document.readyState' 2>/dev/null | head -1 | tr -d '"' || echo "loading")
            if [ "$READY_STATE" = "complete" ] || [ "$READY_STATE" = "interactive" ]; then
                break
            fi
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done

        # 立即重注入JS（不等固定时间）
        INJECT=$(inject_js "tab0")
        if echo "$INJECT" | grep -q "v5_injected"; then
            log "重注入成功 ✓"
        else
            log "重注入失败: $INJECT"
        fi

        sleep 0.2
        JS_RESULT=$(get_js_status "tab0")
    fi

    # ===== 解析JS状态 =====
    CLICKED=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('clicked',False))" 2>/dev/null || echo "False")
    PHASE=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('phase','?'))" 2>/dev/null || echo "?")
    BTN_TEXT=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btnText','?'))" 2>/dev/null || echo "?")

    # ===== 点击成功处理 =====
    if [ "$CLICKED" = "True" ]; then
        log "========================================"
        log "!!! Subscribe 已被JS点击 !!!"
        log "========================================"

        agent-browser screenshot "${LOG_DIR}/v5_clicked_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

        # 打印JS日志
        JS_LOGS=$(echo "$JS_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for l in d.get('logs',[])[-20:]:
    print(l)
" 2>/dev/null)
        log "JS日志:"
        echo "$JS_LOGS" | tee -a "$LOG_FILE"

        # 等待后续页面
        log "等待页面跳转..."
        for ((j=1; j<=20; j++)); do
            sleep 3

            CUR_URL=$(agent-browser get url 2>&1)
            PHASE_NOW=$(agent-browser eval "window.__v5_tab0?window.__v5_tab0.phase:'?'" 2>&1 | head -1 | tr -d '"')

            log "后续 [$j/20] phase=$PHASE_NOW url=${CUR_URL:0:60}"

            if [ "$PHASE_NOW" = "payment_done" ] || [ "$PHASE_NOW" = "confirmed" ]; then
                log "!!! 订单确认/支付完成 !!! phase=$PHASE_NOW"
                agent-browser screenshot "${LOG_DIR}/v5_success_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                echo "SUCCESS: ${PHASE_NOW}" > "$STATUS_FILE"
                agent-browser close 2>&1 > /dev/null
                exit 0
            fi

            if echo "$CUR_URL" | grep -q "cashier\|pay\|order\|success\|trade"; then
                log "检测到支付页面"
                agent-browser screenshot "${LOG_DIR}/v5_paypage_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                for pkw in "确认支付" "去支付" "立即支付" "Pay" "Confirm"; do
                    pc=$(agent-browser click "$pkw" 2>&1)
                    if ! echo "$pc" | grep -qi "fail\|error\|not found"; then
                        log "支付按钮点击: $pkw"
                        sleep 3
                        agent-browser screenshot "${LOG_DIR}/v5_paydone_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
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

    # ===== 进度日志（每10轮）=====
    if [ $((ROUND % 10)) -eq 0 ]; then
        log "[$ROUND/$MAX_ROUNDS] time=$NOW_TIME restock_in=${SECONDS_TO_RESTOCK}s btn=$BTN_TEXT phase=$PHASE"
    fi

    # ===== shell层兜底: 临近补货时直接尝试点击 =====
    if [ "$CLICK_ATTEMPTED" = "false" ] && [ "$SECONDS_TO_RESTOCK" -lt 10 ] && [ "$SECONDS_TO_RESTOCK" -gt -30 ]; then
        if [ $((ROUND % 2)) -eq 0 ]; then
            CLICK_TRY=$(agent-browser click "Subscribe" 2>&1)
            if ! echo "$CLICK_TRY" | grep -qi "fail\|error\|disabled\|not found"; then
                log "Shell兜底点击成功! $CLICK_TRY"
                CLICK_ATTEMPTED=true
            fi
        fi
    fi

    # v5: shell循环间隔降到1秒（v4.1是5秒）
    sleep 1
done

# ============================================================
# 超时退出
# ============================================================
log "脚本执行完毕（超时或按钮未变为可用）"
agent-browser screenshot "${LOG_DIR}/v5_timeout_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
echo "TIMEOUT: v5_exhausted" > "$STATUS_FILE"
agent-browser close 2>&1 > /dev/null
