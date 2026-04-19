#!/bin/bash
# ============================================================
# 阿里百炼 v5 监控循环（轻量版）
# 前提：浏览器已启动、state 已加载、购买页已打开、JS 已注入
# 本脚本只负责：reload + 重注入 + 检查结果
# ============================================================

set -uo pipefail

LOG_DIR="/home/z/my-project/download/coding-plan-grab"
LOG_FILE="${LOG_DIR}/v5_loop_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="${LOG_DIR}/purchase_status.txt"
BUY_PAGE="https://common-buy.aliyun.com/coding-plan"

RESTOCK_TIME="09:30:00"
RESTOCK_EPOCH=$(date -d "$(date +%Y-%m-%d) $RESTOCK_TIME" +%s 2>/dev/null || echo 0)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

# JS代码（精简版，只做监控+点击）
TURBO_JS='(function(){
    window.__v5_tab0={
        started:true,phase:"monitoring",clicked:false,clickTime:null,logs:[],
        startTime:Date.now(),btnText:"",btnDisabled:true
    };
    var R=window.__v5_tab0;
    function log(msg){var ms=Date.now()-R.startTime;R.logs.push("["+ms+"ms] "+msg);if(R.logs.length>500)R.logs.shift();}
    log("v5 loop re-injected | "+document.readyState+" | "+location.href);
    function findBtn(){
        var btns=document.querySelectorAll("button");
        for(var i=0;i<btns.length;i++){
            var b=btns[i];var rect=b.getBoundingClientRect();
            if(rect.width===0&&rect.height===0)continue;
            var t=(b.textContent||"").trim();
            if(t.indexOf("Subscribe")!==-1||t.indexOf("out of stock")!==-1||
               t.indexOf("订阅")!==-1||t.indexOf("购买")!==-1||t.indexOf("一次性")!==-1){
                var dis=b.disabled||b.getAttribute("disabled")!==null;
                R.btnText=t.substring(0,60);R.btnDisabled=dis;
                return{el:b,text:t,disabled:dis};
            }
        }
        return null;
    }
    function onButtonEnabled(btn){
        log("!!! BUTTON ENABLED !!! "+btn.text);
        try{btn.el.click();}catch(e){
            try{btn.el.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window}));}catch(e2){}
        }
        R.clicked=true;R.clickTime=Date.now();R.phase="clicked_subscribe";
        log("CLICKED! elapsed="+(Date.now()-R.startTime)+"ms");
        clearInterval(iv);try{obs.disconnect();}catch(e){}
    }
    var obs=new MutationObserver(function(){
        if(R.clicked)return;var r=findBtn();if(r&&!r.disabled)onButtonEnabled(r);
    });
    try{obs.observe(document.body,{childList:true,subtree:true,attributes:true,
        attributeFilter:["class","disabled","style","aria-disabled","data-status","data-state","data-soldout"]});
    }catch(e){}
    var iv=setInterval(function(){
        if(R.clicked){clearInterval(iv);return;}
        var r=findBtn();if(r&&!r.disabled)onButtonEnabled(r);
    },30);
    setTimeout(function(){clearInterval(iv);try{obs.disconnect();}catch(e){}
        if(!R.clicked){R.phase="timeout";log("Timeout 30min");}},1800000);
    return "v5_injected";
})()'

log "v5 监控循环启动"

LAST_RELOAD=0
ROUND=0
MAX_ROUNDS=1200

while [ $ROUND -lt $MAX_ROUNDS ]; do
    ROUND=$((ROUND + 1))
    NOW=$(date +%s)
    NOW_TIME=$(date +%H:%M:%S)
    SECONDS_TO_RESTOCK=$((RESTOCK_EPOCH - NOW))

    # 检查status
    CURRENT_STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "RUNNING")
    if echo "$CURRENT_STATUS" | grep -q "SUCCESS"; then
        log "检测到成功状态，退出"
        exit 0
    fi

    # 动态reload间隔
    if [ "$SECONDS_TO_RESTOCK" -gt 600 ]; then
        RELOAD_INTERVAL=30
    elif [ "$SECONDS_TO_RESTOCK" -gt 300 ]; then
        RELOAD_INTERVAL=15
    elif [ "$SECONDS_TO_RESTOCK" -gt 120 ]; then
        RELOAD_INTERVAL=8
    elif [ "$SECONDS_TO_RESTOCK" -gt 30 ]; then
        RELOAD_INTERVAL=3
    elif [ "$SECONDS_TO_RESTOCK" -gt -5 ]; then
        RELOAD_INTERVAL=1
    else
        RELOAD_INTERVAL=2
    fi

    SECONDS_SINCE_RELOAD=$((NOW - LAST_RELOAD))

    # 获取JS状态
    JS_RESULT=$(agent-browser eval 'JSON.stringify(window.__v5_tab0||{error:"lost"})' 2>/dev/null | head -1 || echo '{"error":"eval_failed"}')
    JS_ALIVE=true
    if echo "$JS_RESULT" | grep -q "lost\|error"; then
        JS_ALIVE=false
    fi

    # reload
    NEED_RELOAD=false
    if [ "$JS_ALIVE" = false ]; then
        NEED_RELOAD=true
    elif [ "$SECONDS_SINCE_RELOAD" -ge "$RELOAD_INTERVAL" ]; then
        NEED_RELOAD=true
    fi

    if [ "$NEED_RELOAD" = true ]; then
        LAST_RELOAD=$NOW
        log "Reload | round=$ROUND time=$NOW_TIME to_restock=${SECONDS_TO_RESTOCK}s interval=${RELOAD_INTERVAL}s"
        agent-browser reload 2>&1 > /dev/null
        sleep 2
        # 重注入
        INJECT=$(agent-browser eval "$TURBO_JS" 2>/dev/null | head -1)
        log "重注入: $INJECT"
        sleep 1
        JS_RESULT=$(agent-browser eval 'JSON.stringify(window.__v5_tab0||{error:"lost"})' 2>/dev/null | head -1 || echo '{"error:"lost"}')
    fi

    # 解析状态
    CLICKED=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('clicked',False))" 2>/dev/null || echo "False")
    PHASE=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('phase','?'))" 2>/dev/null || echo "?")
    BTN_TEXT=$(echo "$JS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btnText','?'))" 2>/dev/null || echo "?")

    if [ "$CLICKED" = "True" ]; then
        log "========================================"
        log "!!! Subscribe 已被JS点击 !!!"
        log "========================================"
        agent-browser screenshot "${LOG_DIR}/v5_clicked_$(date +%Y%m%d_%H%M%S).png" 2>&1
        JS_LOGS=$(echo "$JS_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for l in d.get('logs',[])[-20:]:
    print(l)
" 2>/dev/null)
        log "JS日志: $JS_LOGS"
        # 等跳转
        for ((j=1; j<=15; j++)); do
            sleep 3
            CUR_URL=$(agent-browser get url 2>&1)
            PHASE_NOW=$(agent-browser eval 'window.__v5_tab0?window.__v5_tab0.phase:"?"' 2>&1 | head -1 | tr -d '"')
            log "后续 [$j] phase=$PHASE_NOW url=${CUR_URL:0:60}"
            if echo "$CUR_URL" | grep -q "cashier\|pay\|order\|success\|trade"; then
                log "检测到支付页面"
                agent-browser screenshot "${LOG_DIR}/v5_paypage_$(date +%Y%m%d_%H%M%S).png" 2>&1
                for pkw in "确认支付" "去支付" "立即支付" "Pay" "Confirm"; do
                    pc=$(agent-browser click "$pkw" 2>&1)
                    if ! echo "$pc" | grep -qi "fail\|error\|not found"; then
                        log "支付按钮: $pkw"
                        sleep 3
                        echo "SUCCESS: pay_clicked" > "$STATUS_FILE"
                        break
                    fi
                done
                echo "SUCCESS: subscribe_clicked" > "$STATUS_FILE"
                exit 0
            fi
        done
        echo "SUCCESS: subscribe_clicked" > "$STATUS_FILE"
        exit 0
    fi

    if [ "$PHASE" = "timeout" ]; then
        log "JS超时"
        break
    fi

    # shell兜底点击
    if [ "$SECONDS_TO_RESTOCK" -lt 10 ] && [ "$SECONDS_TO_RESTOCK" -gt -30 ]; then
        if [ $((ROUND % 2)) -eq 0 ]; then
            CLICK_TRY=$(agent-browser click "Subscribe" 2>&1)
            if ! echo "$CLICK_TRY" | grep -qi "fail\|error\|disabled\|not found"; then
                log "Shell兜底点击成功! $CLICK_TRY"
                echo "SUCCESS: shell_click" > "$STATUS_FILE"
                exit 0
            fi
        fi
    fi

    if [ $((ROUND % 10)) -eq 0 ]; then
        log "[$ROUND] time=$NOW_TIME restock_in=${SECONDS_TO_RESTOCK}s btn=$BTN_TEXT"
    fi

    sleep 1
done

log "监控循环结束"
echo "TIMEOUT: v5_loop_exhausted" > "$STATUS_FILE"
