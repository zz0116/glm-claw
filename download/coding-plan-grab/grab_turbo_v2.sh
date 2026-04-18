#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 极速抢购脚本 v2.1
# 修复: URL检查从15秒降到2秒、处理弹窗、SPA路由兼容、更健壮
# ============================================================

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/turbo_v2_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
PAGE_URL="https://bailian.console.aliyun.com/cn-beijing?tab=coding-plan#/efm/coding-plan-index"
PAGE_URL_ALT="https://bailian.console.aliyun.com/cn-beijing?tab=coding-plan"
BUY_URL="https://common-buy.aliyun.com/?commodityCode=sfm_platform_public_cn"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

log "=== 阿里百炼 Coding Plan 极速抢购脚本 v2.1 启动 ==="

# 清除旧状态
echo "RUNNING" > "$STATUS_FILE"

# 检查 browser state 文件
if [ ! -f "$BROWSER_STATE" ]; then
    log "ERROR: 浏览器状态文件不存在: $BROWSER_STATE"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi
log "浏览器状态文件存在 ($(du -h "$BROWSER_STATE" | cut -f1))"

# 加载浏览器登录状态
log "加载浏览器登录状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
sleep 2

# 打开购买页面 - 先尝试主URL
log "打开百炼 Coding Plan 页面..."
agent-browser open "$PAGE_URL" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 8

# 验证页面是否加载正确（检查是否在coding plan页面）
page_check=$(agent-browser eval '(function(){try{return document.querySelector("[class*=coding-plan]") ? "coding_plan_found" : document.querySelector("button") ? "buttons_found" : "unknown"}catch(e){return "error:"+e.message}})()' 2>/dev/null | head -1)
log "页面内容检查: $page_check"

# 如果主URL没正确加载，尝试备用URL
if [ "$page_check" = "unknown" ] || echo "$page_check" | grep -q "error"; then
    log "主URL加载异常，尝试备用URL..."
    agent-browser open "$PAGE_URL_ALT" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
    sleep 8
fi

# ============================================================
# Phase 1: 注入极速JavaScript
# ============================================================
# 改进:
# - 更全面的按钮文字匹配
# - 同时处理"售罄->有货"状态变化（SPA可能不刷新，只改按钮样式）
# - 点击后记录目标URL，方便shell层快速检测
# - 处理弹窗（target="_blank"）

FAST_CLICK_JS='
(function() {
    window.__turboResult = { 
        clicked: false, apiSuccess: false, phase: "monitoring", 
        clickTime: null, logs: [], startTime: Date.now(),
        targetUrl: null, lastCheckUrl: null, soldOut: true
    };
    const R = window.__turboResult;
    
    function log(msg) {
        const ts = Date.now() - R.startTime;
        R.logs.push("[" + ts + "ms] " + msg);
    }
    
    // ========== 策略A: DOM极速点击 ==========
    function findAndClickBuyButton() {
        if (R.clicked) return false;
        
        // 更全面的选择器
        const allElements = document.querySelectorAll(
            "button, a, [role=button], div[class*=btn], span[class*=btn], " +
            "div[class*=buy], span[class*=buy], div[class*=purchase], " +
            "div[class*=order], [class*=subscribe], [class*=next-]"
        );
        
        for (const el of allElements) {
            const text = (el.textContent || "").trim();
            
            // 跳过隐藏元素
            const rect = el.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            
            // 跳过disabled元素
            const isDisabled = el.disabled || el.hasAttribute("disabled") || 
                               el.classList.contains("is-disabled") || 
                               el.classList.contains("disabled") ||
                               el.getAttribute("aria-disabled") === "true" ||
                               el.style.pointerEvents === "none" ||
               el.style.opacity === "0.5" ||
               el.style.opacity === "0.4" ||
               el.style.display === "none" ||
               el.style.visibility === "hidden";
            
            if (isDisabled) continue;
            
            // 匹配购买按钮 - 更全面的文字匹配
            const isBuyButton = 
                text === "去购买" || text.includes("去购买") || 
                text === "立即购买" || text.includes("立即购买") ||
                text === "立即订阅" || text.includes("立即订阅") ||
                text === "购买" && text.length <= 6 ||
                text === "订阅" && text.length <= 6;
            
            if (isBuyButton) {
                log("FOUND buy button: text=[" + text + "] tag=" + el.tagName);
                
                // 先检查是否有target="_blank"（会打开新窗口）
                const target = el.getAttribute("target") || (el.tagName === "A" ? el.target : "");
                const href = el.getAttribute("href") || (el.tagName === "A" ? el.href : "");
                
                if (href && (href.includes("common-buy") || href.includes("coding-plan")) && target === "_blank") {
                    // 弹窗情况：拦截弹窗，改为当前窗口导航
                    log("Detected popup link, converting to current-tab navigation");
                    el.removeAttribute("target");
                    el.addEventListener("click", function(e) { e.preventDefault(); window.location.href = href; }, {once: true});
                }
                
                try {
                    el.click();
                    R.clicked = true;
                    R.clickTime = Date.now();
                    R.phase = "clicked_buy";
                    log("CLICKED buy button! Time: " + (Date.now() - R.startTime) + "ms");
                    
                    // 记录可能的目标URL
                    if (href) R.targetUrl = href;
                    
                    return true;
                } catch(e) {
                    log("Click error: " + e.message);
                    try {
                        el.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window}));
                        R.clicked = true;
                        R.clickTime = Date.now();
                        R.phase = "clicked_buy";
                        log("CLICKED via dispatchEvent!");
                        return true;
                    } catch(e2) {
                        log("dispatchEvent failed: " + e2.message);
                    }
                }
            }
        }
        return false;
    }
    
    // ========== MutationObserver ==========
    const observer = new MutationObserver(function(mutations) {
        findAndClickBuyButton();
    });
    
    try {
        observer.observe(document.body, { 
            childList: true, subtree: true, attributes: true, 
            attributeFilter: ["class", "disabled", "style", "aria-disabled", "data-state"] 
        });
        log("MutationObserver started");
    } catch(e) {
        log("MutationObserver error: " + e.message);
    }
    
    // ========== setInterval 50ms ==========
    const interval = setInterval(function() {
        const found = findAndClickBuyButton();
        if (found) {
            clearInterval(interval);
            observer.disconnect();
            log("Buy button clicked via interval! Phase 1 complete.");
        }
    }, 50);
    
    // ========== 策略B: 浏览器内API调用 ==========
    (async function apiPurchaseLoop() {
        log("API purchase loop starting (100ms intervals)...");
        let apiRound = 0;
        const MAX_ROUNDS = 3600;
        
        while (apiRound < MAX_ROUNDS && !R.apiSuccess && !R.clicked) {
            apiRound++;
            
            try {
                // 检查库存
                const invResp = await fetch("/cn-beijing/api/coding-plan/inventory", {
                    credentials: "include",
                    headers: { "Content-Type": "application/json" }
                }).catch(() => null);
                
                if (invResp && invResp.ok) {
                    const invData = await invResp.json().catch(() => null);
                    
                    // 记录库存数据用于调试
                    if (apiRound === 1) {
                        log("API: inventory response structure: " + JSON.stringify(invData).substring(0, 300));
                    }
                    
                    // 尝试多种可能的库存字段名
                    let hasStock = false;
                    if (invData && invData.data) {
                        const d = invData.data;
                        if (d.inventoryNum > 0) hasStock = true;
                        if (d.inventory > 0) hasStock = true;
                        if (d.stock > 0) hasStock = true;
                        if (d.canBuy === true || d.canBuy === "true") hasStock = true;
                        if (d.available === true || d.available === "true") hasStock = true;
                        if (d.status === "available" || d.status === "in_stock") hasStock = true;
                    }
                    
                    if (hasStock) {
                        log("API: STOCK DETECTED! data=" + JSON.stringify(invData.data).substring(0, 200));
                        
                        // 尝试跳转购买页
                        if (!R.clicked) {
                            log("API: Navigating to buy page...");
                            R.clicked = true;
                            R.targetUrl = "https://common-buy.aliyun.com/?commodityCode=sfm_platform_public_cn";
                            window.location.href = R.targetUrl;
                            return;
                        }
                    }
                }
            } catch(e) {
                if (apiRound <= 3) log("API loop error: " + e.message);
            }
            
            await new Promise(r => setTimeout(r, 100));
        }
        log("API purchase loop ended after " + apiRound + " rounds");
    })();
    
    // 拦截 window.open 防止弹窗
    const origOpen = window.open;
    window.open = function(url) {
        log("Intercepted window.open: " + url);
        if (url && (url.includes("common-buy") || url.includes("coding-plan"))) {
            R.targetUrl = url;
            R.clicked = true;
            window.location.href = url;
            return null;
        }
        return origOpen.apply(window, arguments);
    };
    
    // 10分钟后清理
    setTimeout(function() {
        clearInterval(interval);
        try { observer.disconnect(); } catch(e) {}
        log("Auto cleanup after 10 minutes");
    }, 600000);
    
    log("Turbo v2.1 initialized - ultra-fast monitoring active");
})();
'

log "注入极速JavaScript..."
agent-browser eval "$FAST_CLICK_JS" 2>&1 | tee -a "$LOG_FILE"
sleep 2

# 验证JS注入成功
js_init=$(agent-browser eval 'JSON.stringify(window.__turboResult ? {phase:window.__turboResult.phase, logCount:window.__turboResult.logs.length} : {error:"not_injected"})' 2>/dev/null | head -1)
log "JS注入状态: $js_init"

if echo "$js_init" | grep -q "not_injected"; then
    log "WARNING: JS注入可能失败！尝试重新注入..."
    sleep 3
    agent-browser eval "$FAST_CLICK_JS" 2>&1 | tee -a "$LOG_FILE"
    sleep 2
fi

log "极速监控模式已启动"

# ============================================================
# Phase 2: 高频监控（每2秒检查一次，而非15秒）
# ============================================================
MONITOR_ROUNDS=180  # 监控6分钟 (每2秒一次)
PHASE2_CLICKED=false

for ((i=1; i<=MONITOR_ROUNDS; i++)); do
    sleep 2
    
    # 每2秒检查一次JS状态和URL（关键改进！）
    js_result=$(agent-browser eval 'JSON.stringify(window.__turboResult || {error:"not_found"})' 2>/dev/null | head -1)
    current_url=$(agent-browser get url 2>/dev/null)
    
    # 解析JS结果
    if [ -n "$js_result" ]; then
        clicked=$(echo "$js_result" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('clicked',False))
except: print(False)
" 2>/dev/null)
        
        api_success=$(echo "$js_result" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('apiSuccess',False))
except: print(False)
" 2>/dev/null)
        
        phase=$(echo "$js_result" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('phase','unknown'))
except: print('unknown')
" 2>/dev/null)
        
        # API成功
        if [ "$api_success" = "True" ]; then
            log "!!! API购买成功 !!!"
            echo "SUCCESS: api_purchase" > "$STATUS_FILE"
            agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/api_success_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
            agent-browser close 2>&1 > /dev/null
            exit 0
        fi
        
        # JS检测到点击
        if [ "$clicked" = "True" ] && [ "$PHASE2_CLICKED" = "false" ]; then
            PHASE2_CLICKED=true
            click_time=$(echo "$js_result" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('clickTime','') or '')
except: print('')
" 2>/dev/null)
            log "JS已点击购买按钮! phase=$phase clickTime=$click_time"
            
            # 输出JS日志
            js_logs=$(echo "$js_result" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    logs=d.get('logs',[])
    for l in logs[-5:]: print(l)
except: pass
" 2>/dev/null)
            log "JS日志: $js_logs"
        fi
    fi
    
    # 每4秒（每2轮）记录进度
    if (( i % 3 == 0 )); then
        log "监控中 [${i}/${MONITOR_ROUNDS}] | URL: ${current_url:0:80} | phase: ${phase:-unknown}"
    fi
    
    # 检测是否跳转到购买确认页面 common-buy (每次都检查！)
    if echo "$current_url" | grep -q "common-buy"; then
        log "!!! 已跳转到购买确认页面 !!!"
        
        # Phase 2: 在购买确认页面注入极速点击JS
        CONFIRM_JS='
(function() {
    window.__confirmResult = { clicked: false, logs: [], startTime: Date.now() };
    const R = window.__confirmResult;
    function log(msg) { R.logs.push("[" + (Date.now()-R.startTime) + "ms] " + msg); }
    
    // 先点击所有协议checkbox
    setTimeout(function() {
        var cbs = document.querySelectorAll("input[type=checkbox]");
        for (var i = 0; i < cbs.length; i++) {
            if (!cbs[i].checked && (cbs[i].id.toLowerCase().includes("agree") || 
                cbs[i].id.toLowerCase().includes("term") ||
                cbs[i].name.toLowerCase().includes("agree") ||
                cbs[i].closest("[class*=agreement]") || cbs[i].closest("[class*=term]") ||
                cbs[i].closest("[class*=protocol]") ||
                cbs[i].parentElement.textContent.includes("同意") ||
                cbs[i].parentElement.textContent.includes("协议"))) {
                cbs[i].click();
                log("Checked agreement: " + cbs[i].id);
            }
        }
    }, 200);
    
    function findAndClickConfirm() {
        if (R.clicked) return false;
        var allBtns = document.querySelectorAll("button, a, [role=button], input[type=submit], [class*=btn-primary]");
        var keywords = ["立即购买", "提交订单", "确认订单", "去支付", "立即支付", "确认支付", "下一步", "buy", "purchase", "submit", "confirm", "创建订单"];
        
        for (var i = 0; i < allBtns.length; i++) {
            var el = allBtns[i];
            var text = (el.textContent || el.value || "").trim();
            var textLower = text.toLowerCase();
            var isDisabled = el.disabled || el.getAttribute("disabled") !== null || 
                               el.classList.contains("is-disabled") || 
                               el.classList.contains("disabled") ||
                               el.style.pointerEvents === "none" ||
                               el.style.display === "none";
            
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            
            if (isDisabled) continue;
            
            for (var j = 0; j < keywords.length; j++) {
                if (textLower.indexOf(keywords[j].toLowerCase()) !== -1 && text.length < 20) {
                    log("FOUND: " + text);
                    el.click();
                    R.clicked = true;
                    log("CLICKED!");
                    return true;
                }
            }
        }
        return false;
    }
    
    // MutationObserver + setInterval 双保险
    var obs = new MutationObserver(function() { findAndClickConfirm(); });
    try { obs.observe(document.body, {childList:true, subtree:true, attributes:true}); } catch(e) {}
    
    var iv = setInterval(function() {
        if (findAndClickConfirm()) { clearInterval(iv); try { obs.disconnect(); } catch(e) {} }
    }, 50);
    
    setTimeout(function() { clearInterval(iv); try { obs.disconnect(); } catch(e) {} }, 120000);
    log("Confirm page monitor started");
})();
'
        agent-browser eval "$CONFIRM_JS" 2>&1 | tee -a "$LOG_FILE"
        
        # 截图
        agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/confirm_page_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
        
        # 等待确认页面处理（最多等30秒）
        CONFIRM_WAIT=15
        for ((j=1; j<=CONFIRM_WAIT; j++)); do
            sleep 2
            new_url=$(agent-browser get url 2>/dev/null)
            new_confirm=$(agent-browser eval 'JSON.stringify(window.__confirmResult || {})' 2>/dev/null | head -1)
            confirm_clicked=$(echo "$new_confirm" | python3 -c "import sys,json; print(json.load(sys.stdin).get('clicked',False))" 2>/dev/null)
            
            log "确认页面等待中 [${j}/${CONFIRM_WAIT}] | clicked: ${confirm_clicked} | URL: ${new_url:0:80}"
            
            # 如果跳转到支付/收银台页面
            if echo "$new_url" | grep -q "cashier\|pay\|payment\|order"; then
                log "!!! 已跳转到支付页面 !!!"
                
                # Phase 3: 支付页面自动确认
                PAY_JS='
(function() {
    window.__payResult = { clicked: false };
    var R = window.__payResult;
    
    function clickPay() {
        if (R.clicked) return;
        var btns = document.querySelectorAll("button, a, [role=button], input[type=submit]");
        var kws = ["确认支付", "去支付", "立即支付", "pay now", "余额支付", "确认付款", "comfirm", "alipay"];
        for (var i = 0; i < btns.length; i++) {
            var el = btns[i];
            var t = (el.textContent || el.value || "").trim().toLowerCase();
            var dis = el.disabled || el.classList.contains("is-disabled") || el.classList.contains("disabled");
            for (var j = 0; j < kws.length; j++) {
                if (t.indexOf(kws[j].toLowerCase()) !== -1 && !dis) {
                    el.click();
                    R.clicked = true;
                    return;
                }
            }
        }
    }
    
    // 尝试选择余额支付
    setTimeout(function() {
        var labels = document.querySelectorAll("label, div, span");
        for (var i = 0; i < labels.length; i++) {
            var text = labels[i].textContent || "";
            if ((text.includes("余额") || text.includes("account balance")) && !text.includes("支付宝")) {
                labels[i].click();
                break;
            }
        }
        var radios = document.querySelectorAll("input[type=radio]");
        for (var i = 0; i < radios.length; i++) {
            if (radios[i].id && radios[i].id.toLowerCase().includes("balance")) {
                radios[i].click();
                break;
            }
        }
        clickPay();
    }, 500);
    
    var obs = new MutationObserver(function() { clickPay(); });
    try { obs.observe(document.body, {childList:true, subtree:true}); } catch(e) {}
    var iv = setInterval(function() { if(clickPay()) { clearInterval(iv); try{obs.disconnect();}catch(e){} } }, 100);
    setTimeout(function() { clearInterval(iv); try{obs.disconnect();}catch(e){} }, 60000);
})();
'
                agent-browser eval "$PAY_JS" 2>&1 | tee -a "$LOG_FILE"
                sleep 5
                agent-browser screenshot "/home/z/my-project/download/coding-plan-grab/pay_page_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                
                log "========== 购买流程已触发！等待支付确认 =========="
                echo "SUCCESS: browser_purchase_triggered" > "$STATUS_FILE"
                agent-browser close 2>&1 > /dev/null
                exit 0
            fi
            
            # 如果确认按钮已点击，继续等跳转
            if [ "$confirm_clicked" = "True" ]; then
                log "确认购买按钮已点击，等待页面跳转..."
                continue
            fi
        done
        
        log "确认页面等待超时，但流程已触发"
        echo "SUCCESS: browser_purchase_triggered" > "$STATUS_FILE"
        agent-browser close 2>&1 > /dev/null
        exit 0
    fi
    
    # 检查状态文件（外部可能修改）
    if [ -f "$STATUS_FILE" ]; then
        status=$(cat "$STATUS_FILE")
        if [[ "$status" == SUCCESS* ]]; then
            log "已标记为成功，退出"
            agent-browser close 2>&1 > /dev/null
            exit 0
        fi
    fi
done

# 最终状态
final_result=$(agent-browser eval 'JSON.stringify(window.__turboResult || {})' 2>/dev/null | head -1)
final_logs=$(echo "$final_result" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    logs=d.get('logs',[])
    for l in logs[-10:]: print(l)
except: pass
" 2>/dev/null)
log "最终状态: $final_logs"

log "极速抢购脚本执行完毕"
echo "TIMEOUT: turbo_v2.1_exhausted" > "$STATUS_FILE"
agent-browser close 2>&1 > /dev/null
