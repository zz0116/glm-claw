#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 极速抢购脚本 v3 (终极版)
#
# 核心策略：
#   1. 直接打开 common-buy.aliyun.com/coding-plan（跳过百炼控制台）
#   2. 等页面完全加载后，注入本地JS (MutationObserver + 50ms轮询)
#   3. JS在浏览器本地自动检测按钮状态变化 → 自动点击 → 自动提交
#   4. 外层bash只负责初始化和结果收集
#
# v2.1 失败原因：
#   - 从百炼控制台跳转浪费8秒
#   - eval在SPA上返回null（页面没加载完就注入）
#   - 到达购买页时按钮已disabled
#
# v3 改进：
#   - 直接导航购买页，省去跳转时间
#   - 等页面完全渲染后再注入JS
#   - JS注入后50ms本地轮询，速度远超外部指令
#   - 兼容方案：eval失败则降级为 agent-browser click 轮询
# ============================================================

set -o pipefail

BROWSER_STATE="/home/z/my-project/download/coding-plan-grab/browser_state.json"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/turbo_v3_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
BUY_PAGE="https://common-buy.aliyun.com/?commodityCode=sfm_platform_public_cn"
BUY_PAGE_ALT="https://common-buy.aliyun.com/coding-plan"
SCREENSHOT_DIR="/home/z/my-project/download/coding-plan-grab"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

log "============================================================"
log "=== 阿里百炼 Coding Plan Pro 极速抢购脚本 v3 终极版 ==="
log "============================================================"

echo "RUNNING" > "$STATUS_FILE"

# ============================================================
# 0. 检查 browser_state
# ============================================================
if [ ! -f "$BROWSER_STATE" ]; then
    log "FATAL: browser_state.json 不存在"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi

STATE_SIZE=$(stat -c%s "$BROWSER_STATE" 2>/dev/null || echo 0)
log "browser_state: $(du -h "$BROWSER_STATE" | cut -f1) ($STATE_SIZE bytes)"

if [ "$STATE_SIZE" -lt 100000 ]; then
    log "FATAL: browser_state 太小 (${STATE_SIZE}B)，可能已失效，需要重新登录"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi

# ============================================================
# 1. 启动浏览器 & 加载登录态
# ============================================================
log "加载浏览器状态..."
agent-browser state load "$BROWSER_STATE" 2>&1 | tee -a "$LOG_FILE"
sleep 2

# ============================================================
# 2. 直接打开购买确认页
# ============================================================
log "直接导航到购买页: $BUY_PAGE"
agent-browser open "$BUY_PAGE" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
sleep 5

# 检查是否到了购买页
CURRENT_URL=$(agent-browser get url 2>/dev/null)
log "当前URL: $CURRENT_URL"

if ! echo "$CURRENT_URL" | grep -q "common-buy"; then
    log "主URL未跳转到购买页，尝试备用URL..."
    agent-browser open "$BUY_PAGE_ALT" --timeout 30000 2>&1 | tee -a "$LOG_FILE"
    sleep 8
    CURRENT_URL=$(agent-browser get url 2>/dev/null)
    log "当前URL: $CURRENT_URL"
fi

# 截图初始状态
agent-browser screenshot "$SCREENSHOT_DIR/v3_initial_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

# 获取页面快照（用于分析按钮状态）
INITIAL_SNAP=$(agent-browser snapshot -i 2>&1)
log "页面快照 (关键部分):"
echo "$INITIAL_SNAP" | grep -iE "subscribe|button|stock|sold|coupon|balance|restock|售罄|购买|disabled" | head -15 | tee -a "$LOG_FILE"

# ============================================================
# 3. 等页面完全渲染（最多等30秒）
# ============================================================
log "等待页面完全渲染..."
PAGE_READY=false
for wait_i in $(seq 1 15); do
    sleep 2
    
    # 用简单的eval测试页面JS环境是否就绪
    TEST_RESULT=$(agent-browser eval 'document.readyState' 2>/dev/null | head -1)
    
    if [ "$TEST_RESULT" = '"complete"' ] || [ "$TEST_RESULT" = "complete" ]; then
        # 再等1秒确保React/Vue渲染完成
        sleep 1
        
        # 测试DOM是否已有实际内容
        BODY_CHECK=$(agent-browser eval 'document.body.innerText.length' 2>/dev/null | head -1)
        log "readyState=$TEST_RESULT bodyLength=$BODY_CHECK (wait ${wait_i}/15)"
        
        if [ -n "$BODY_CHECK" ] && [ "$BODY_CHECK" -gt 500 ] 2>/dev/null; then
            PAGE_READY=true
            log "页面已完全渲染！"
            break
        fi
    else
        log "等待渲染中... readyState=$TEST_RESULT (${wait_i}/15)"
    fi
done

if [ "$PAGE_READY" = "false" ]; then
    log "WARNING: 页面可能未完全渲染，继续尝试..."
fi

# ============================================================
# 4. 注入极速本地JS
# ============================================================
# 这段JS会在浏览器本地以50ms间隔轮询，一旦按钮从disabled变成enabled，
# 立即在本地执行click + 提交操作，零网络延迟。

FAST_BUY_JS='(function(){
    if(window.__v3Active){return "already_injected";}
    window.__v3Active=true;
    window.__v3Result={phase:"init",clicked:false,submitted:false,logs:[],startTime:Date.now(),clickTime:null,submitTime:null,errors:[]};
    var R=window.__v3Result;
    
    function log(m){var t=Date.now()-R.startTime;R.logs.push("["+t+"ms] "+m);console.log("[V3] "+m);}
    
    log("Turbo v3 JS loaded, monitoring...");
    R.phase="monitoring";
    
    // ========== 核心函数：查找并点击购买按钮 ==========
    function tryClick(){
        if(R.clicked)return false;
        
        // 查找所有可能的按钮和可点击元素
        var els=document.querySelectorAll("button,[role=button],a[href],.next-btn,[class*=btn],[class*=subscribe],[class*=buy]");
        
        for(var i=0;i<els.length;i++){
            var el=els[i];
            var rect=el.getBoundingClientRect();
            if(rect.width===0&&rect.height===0)continue;
            if(el.style.display==="none"||el.style.visibility==="hidden")continue;
            
            var text=(el.textContent||"").trim().toLowerCase();
            
            // 匹配目标按钮
            var isTarget=false;
            if(text.indexOf("subscribe")!==-1)isTarget=true;
            if(text.indexOf("立即购买")!==-1)isTarget=true;
            if(text.indexOf("立即订阅")!==-1)isTarget=true;
            if(text.indexOf("购买")!==-1&&text.length<10)isTarget=true;
            
            if(!isTarget)continue;
            
            // 检查是否disabled
            var disabled=el.disabled||el.getAttribute("disabled")!==null||
                el.classList.contains("is-disabled")||el.classList.contains("disabled")||
                el.getAttribute("aria-disabled")==="true"||
                el.style.pointerEvents==="none"||
                el.style.opacity==="0.5"||el.style.opacity==="0.4"||
                el.style.cursor==="not-allowed";
            
            if(disabled){
                R.lastDisabled=true;
                return false;
            }
            
            // 按钮可用！立即点击
            log("FOUND ENABLED BUTTON: ["+text+"] tag="+el.tagName);
            
            try{
                el.click();
                R.clicked=true;
                R.clickTime=Date.now();
                R.phase="clicked";
                log("CLICKED! elapsed="+(Date.now()-R.startTime)+"ms");
                return true;
            }catch(e){
                log("click() failed: "+e.message+", trying dispatchEvent...");
                try{
                    el.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window}));
                    R.clicked=true;
                    R.clickTime=Date.now();
                    R.phase="clicked";
                    log("dispatchEvent CLICKED!");
                    return true;
                }catch(e2){
                    log("dispatchEvent also failed: "+e2.message);
                    R.errors.push(e2.message);
                    return false;
                }
            }
        }
        return false;
    }
    
    // ========== MutationObserver ==========
    var observer=new MutationObserver(function(mutations){
        // 只关注属性变化（disabled状态切换）
        for(var i=0;i<mutations.length;i++){
            var m=mutations[i];
            if(m.type==="attributes"&&(m.attributeName==="disabled"||m.attributeName==="class"||m.attributeName==="style"||m.attributeName==="aria-disabled")){
                tryClick();
                if(R.clicked){observer.disconnect();clearInterval(timer);return;}
            }
            // 子节点变化（整个按钮从"售罄提示"替换为"Subscribe按钮"）
            if(m.type==="childList"&&m.addedNodes.length>0){
                setTimeout(tryClick,10); // 等DOM稳定
                if(R.clicked){observer.disconnect();clearInterval(timer);return;}
            }
        }
    });
    
    try{
        observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:["disabled","class","style","aria-disabled","data-state"]});
        log("MutationObserver active");
    }catch(e){
        log("MutationObserver failed: "+e.message);
    }
    
    // ========== 50ms轮询 ==========
    var timer=setInterval(function(){
        tryClick();
        if(R.clicked){
            clearInterval(timer);
            try{observer.disconnect();}catch(e){}
            log("Interval stopped - button clicked");
            
            // 点击后等待3秒，检查是否需要进一步操作
            setTimeout(function(){
                R.phase="post_click";
                log("Post-click check, current URL: "+location.href);
                
                // 检查是否需要勾选协议
                var cbs=document.querySelectorAll("input[type=checkbox]");
                for(var c=0;c<cbs.length;c++){
                    if(!cbs[c].checked){
                        var parentText=cbs[c].parentElement?cbs[c].parentElement.textContent:"";
                        if(parentText.indexOf("同意")!==-1||parentText.indexOf("agree")!==-1||
                           parentText.indexOf("协议")!==-1||parentText.indexOf("term")!==-1||
                           parentText.indexOf("service")!==-1){
                            cbs[c].click();
                            log("Checked agreement checkbox");
                        }
                    }
                }
                
                // 查找并点击确认/提交按钮
                var confirmBtns=document.querySelectorAll("button,[role=button],[class*=btn-primary],[class*=btn-submit]");
                var confirmKws=["submit","confirm","pay","支付","确认","提交","创建订单"];
                for(var b=0;b<confirmBtns.length;b++){
                    var bt=(confirmBtns[b].textContent||"").trim().toLowerCase();
                    var bDisabled=confirmBtns[b].disabled||confirmBtns[b].classList.contains("disabled");
                    if(!bDisabled){
                        for(var k=0;k<confirmKws.length;k++){
                            if(bt.indexOf(confirmKws[k])!==-1){
                                confirmBtns[b].click();
                                R.submitted=true;
                                R.submitTime=Date.now();
                                R.phase="submitted";
                                log("Confirmed/submitted: ["+bt+"]");
                                return;
                            }
                        }
                    }
                }
                log("No additional confirm button found");
            },3000);
        }
    },50);
    
    // 10分钟自动清理
    setTimeout(function(){
        clearInterval(timer);
        try{observer.disconnect();}catch(e){}
        R.phase="timeout";
        log("Auto cleanup after 10min, clicked="+R.clicked);
    },600000);
    
    return "injected_ok";
})()'

# ============================================================
# 5. 尝试注入JS
# ============================================================
log "注入极速JS..."
INJECT_RESULT=$(agent-browser eval "$FAST_BUY_JS" 2>&1 | head -1)
log "注入结果: $INJECT_RESULT"

JS_INJECTED=false
if echo "$INJECT_RESULT" | grep -q "injected_ok"; then
    JS_INJECTED=true
    log "✓ JS注入成功！本地50ms轮询已启动"
elif echo "$INJECT_RESULT" | grep -q "already_injected"; then
    JS_INJECTED=true
    log "✓ JS已存在（之前注入过）"
else
    log "✗ JS注入返回: $INJECT_RESULT"
    
    # 尝试等更长时间再注入
    log "等待5秒后重试..."
    sleep 5
    INJECT_RESULT=$(agent-browser eval "$FAST_BUY_JS" 2>&1 | head -1)
    log "重试结果: $INJECT_RESULT"
    
    if echo "$INJECT_RESULT" | grep -q "injected_ok\|already_injected"; then
        JS_INJECTED=true
        log "✓ JS重试注入成功！"
    fi
fi

if [ "$JS_INJECTED" = "true" ]; then
    # 验证JS状态
    sleep 1
    JS_STATUS=$(agent-browser eval 'JSON.stringify({phase:window.__v3Result?window.__v3Result.phase:"none",logCount:window.__v3Result?window.__v3Result.logs.length:0,lastLogs:window.__v3Result?window.__v3Result.logs.slice(-3):[]})' 2>/dev/null | head -1)
    log "JS状态: $JS_STATUS"
else
    log "⚠ JS注入失败，降级为 agent-browser click 模式"
fi

# ============================================================
# 6. 外层监控循环
# ============================================================
# 即使JS已注入，外层也需要监控来：
#   a) 检测JS是否成功点击（读取window.__v3Result）
#   b) JS失败时降级为 agent-browser click
#   c) 处理点击后的页面跳转（支付确认等）

MAX_ROUNDS=1800  # 15分钟
MODE="hybrid"     # hybrid=JS优先+外层兜底, fallback=纯外层

log "启动外层监控 (${MODE}模式, ${MAX_ROUNDS}轮, 2s/轮)..."

for ((i=1; i<=MAX_ROUNDS; i++)); do
    sleep 2
    
    # ------ 检查JS执行状态 ------
    if [ "$JS_INJECTED" = "true" ]; then
        JS_CHECK=$(agent-browser eval 'JSON.stringify(window.__v3Result||{error:"lost"})' 2>/dev/null | head -1)
        
        if [ -n "$JS_CHECK" ]; then
            JS_CLICKED=$(echo "$JS_CHECK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('clicked',False))" 2>/dev/null)
            JS_PHASE=$(echo "$JS_CHECK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('phase','unknown'))" 2>/dev/null)
            JS_SUBMITTED=$(echo "$JS_CHECK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('submitted',False))" 2>/dev/null)
            
            # JS已点击！
            if [ "$JS_CLICKED" = "True" ]; then
                JS_LOGS=$(echo "$JS_CHECK" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(l) for l in d.get('logs',[])[-8:]]" 2>/dev/null)
                log "!!! JS本地点击成功 !!! phase=$JS_PHASE submitted=$JS_SUBMITTED"
                log "JS日志: $JS_LOGS"
                
                # 截图
                agent-browser screenshot "$SCREENSHOT_DIR/v3_js_clicked_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                
                # 等待页面跳转
                sleep 5
                NEW_URL=$(agent-browser get url 2>/dev/null)
                log "点击后URL: $NEW_URL"
                
                if echo "$NEW_URL" | grep -q "cashier\|pay\|payment\|order"; then
                    log "!!! 已跳转到支付页面 !!!"
                    handle_payment_page
                    exit 0
                fi
                
                # 如果还在购买页，可能需要点确认按钮
                if echo "$NEW_URL" | grep -q "common-buy"; then
                    log "仍在购买页，尝试点击确认按钮..."
                    for confirm_kw in "立即购买" "提交订单" "确认订单" "Subscribe" "Submit" "Confirm"; do
                        click_result=$(agent-browser click "$confirm_kw" 2>&1)
                        if ! echo "$click_result" | grep -qi "fail\|error\|not found"; then
                            log "确认按钮点击: $confirm_kw -> $click_result"
                            sleep 3
                            agent-browser screenshot "$SCREENSHOT_DIR/v3_confirmed_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
                            break
                        fi
                    done
                    
                    FINAL_URL=$(agent-browser get url 2>/dev/null)
                    if echo "$FINAL_URL" | grep -q "cashier\|pay\|order"; then
                        handle_payment_page
                    fi
                fi
                
                echo "SUCCESS: js_auto_clicked" > "$STATUS_FILE"
                log "========== JS自动点击成功！流程已触发 =========="
                agent-browser close 2>&1 > /dev/null
                exit 0
            fi
        fi
    fi
    
    # ------ 降级：agent-browser click（每6轮=12秒尝试一次，减少开销）------
    if (( i % 6 == 0 )); then
        # 先检查URL是否已变
        CURRENT_URL=$(agent-browser get url 2>/dev/null)
        
        if echo "$CURRENT_URL" | grep -q "cashier\|pay\|payment\|order\|success"; then
            log "!!! 检测到已跳转支付页面 !!!"
            handle_payment_page
            exit 0
        fi
        
        # 获取快照检查按钮状态
        SNAP=$(agent-browser snapshot -i 2>&1)
        SUB_LINE=$(echo "$SNAP" | grep -i "Subscribe")
        
        # 如果按钮可用（没有disabled）
        if echo "$SUB_LINE" | grep -q "Subscribe" && ! echo "$SUB_LINE" | grep -qi "disabled"; then
            log "!!! 检测到Subscribe按钮可用！点击！"
            
            SUB_REF=$(echo "$SUB_LINE" | grep -oP '\[ref=\K[^\]]+' | head -1)
            if [ -n "$SUB_REF" ]; then
                agent-browser click "@$SUB_REF" 2>&1 | tee -a "$LOG_FILE"
            else
                agent-browser click "Subscribe" 2>&1 | tee -a "$LOG_FILE"
            fi
            
            sleep 3
            agent-browser screenshot "$SCREENSHOT_DIR/v3_fallback_clicked_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
            
            NEW_URL=$(agent-browser get url 2>/dev/null)
            if echo "$NEW_URL" | grep -q "cashier\|pay\|order"; then
                handle_payment_page
            fi
            
            echo "SUCCESS: fallback_clicked" > "$STATUS_FILE"
            agent-browser close 2>&1 > /dev/null
            exit 0
        fi
    fi
    
    # ------ 每30秒刷新一次页面（防止session过期）------
    if (( i % 15 == 0 )); then
        log "定期刷新页面 [${i}/${MAX_ROUNDS}]..."
        agent-browser reload 2>&1 > /dev/null
        sleep 3
        
        # 刷新后重新注入JS
        if [ "$JS_INJECTED" = "true" ]; then
            sleep 2
            RE_INJECT=$(agent-browser eval "$FAST_BUY_JS" 2>&1 | head -1)
            log "重新注入JS: $RE_INJECT"
        fi
    fi
    
    # ------ 进度日志 ------
    if (( i % 10 == 0 )); then
        CURRENT_URL=$(agent-browser get url 2>/dev/null)
        log "监控中 [${i}/${MAX_ROUNDS}] URL: ${CURRENT_URL:0:60} phase: ${JS_PHASE:-N/A}"
    fi
done

# ============================================================
# 7. 超时
# ============================================================
log "脚本执行完毕，未成功"
echo "TIMEOUT: v3_exhausted" > "$STATUS_FILE"

# 最终截图
agent-browser screenshot "$SCREENSHOT_DIR/v3_timeout_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"

# 输出JS日志（如果有）
if [ "$JS_INJECTED" = "true" ]; then
    FINAL_JS=$(agent-browser eval 'JSON.stringify(window.__v3Result||{})' 2>/dev/null | head -1)
    FINAL_LOGS=$(echo "$FINAL_JS" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(l) for l in d.get('logs',[])[-15:]]" 2>/dev/null)
    log "JS最终日志: $FINAL_LOGS"
fi

agent-browser close 2>&1 > /dev/null

# ============================================================
# 辅助函数
# ============================================================
handle_payment_page() {
    log "========== 处理支付页面 =========="
    agent-browser screenshot "$SCREENSHOT_DIR/v3_payment_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
    
    sleep 2
    
    # 尝试各种支付确认按钮
    for pay_kw in "确认支付" "去支付" "立即支付" "确认付款" "余额支付" "Confirm Payment" "Pay Now" "Confirm"; do
        pay_result=$(agent-browser click "$pay_kw" 2>&1)
        if ! echo "$pay_result" | grep -qi "fail\|error\|not found\|unknown"; then
            log "支付按钮点击成功: $pay_kw"
            sleep 3
            agent-browser screenshot "$SCREENSHOT_DIR/v3_pay_done_$(date +%Y%m%d_%H%M%S).png" 2>&1 | tee -a "$LOG_FILE"
            break
        fi
    done
    
    echo "SUCCESS: payment_triggered" > "$STATUS_FILE"
    log "========== 支付流程已触发 =========="
    agent-browser close 2>&1 > /dev/null
}
