#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan Pro 纯API抢购脚本
# 补货时间: 2026-04-18 09:30 北京时间
# 策略: 高频请求，0.1秒/轮，纯API不依赖页面
# ============================================================

set -euo pipefail

COOKIE_FILE="/home/z/my-project/download/coding-plan-grab/cookies.txt"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/grab_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
REFERER="https://bailian.console.aliyun.com/cn-beijing?tab=coding-plan#/efm/coding-plan-index"

# 购买页面商品信息（从上次会话获取）
COMMODITY_CODE=""  # 需要从页面获取
REGION="cn-beijing"
PROMOTION_INFO=""  # 代金券信息，需要从页面获取

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 阿里百炼 Coding Plan 抢购脚本启动 ==="

# 检查Cookie文件
if [ ! -f "$COOKIE_FILE" ]; then
    log "ERROR: Cookie文件不存在: $COOKIE_FILE"
    log "请先运行 grab_login.sh 获取Cookie"
    echo "NEED_LOGIN" > "$STATUS_FILE"
    exit 1
fi

COOKIE=$(cat "$COOKIE_FILE")
log "Cookie已加载 ($(echo "$COOKIE" | wc -c) bytes)"

# Step 1: 检查库存状态
check_inventory() {
    local response
    response=$(curl -s --max-time 5 \
        -H "User-Agent: $USER_AGENT" \
        -H "Cookie: $COOKIE" \
        -H "Referer: $REFERER" \
        "https://bailian.console.aliyun.com/cn-beijing/api/coding-plan/inventory" 2>&1)
    
    echo "$response"
}

# Step 2: 获取CSRF Token
get_csrf_token() {
    local response
    response=$(curl -s --max-time 5 \
        -H "User-Agent: $USER_AGENT" \
        -H "Cookie: $COOKIE" \
        -H "Referer: https://cashier.aliyun.com/" \
        "https://cashier.aliyun.com/order/ajax/payAjax/getCsrfToken.json" 2>&1)
    
    echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('_csrf_token',''))" 2>/dev/null || echo ""
}

# Step 3: 创建订单
create_order() {
    local csrf_token="$1"
    
    # 先通过页面接口创建订单
    local response
    response=$(curl -s --max-time 10 \
        -X POST \
        -H "User-Agent: $USER_AGENT" \
        -H "Cookie: $COOKIE" \
        -H "Referer: $REFERER" \
        -H "Content-Type: application/json" \
        -H "X-Csrf-Token: $csrf_token" \
        -d "{\"commodityCode\":\"$COMMODITY_CODE\",\"region\":\"$REGION\",\"promotionInfo\":\"$PROMOTION_INFO\"}" \
        "https://bailian.console.aliyun.com/cn-beijing/api/coding-plan/createOrder" 2>&1)
    
    echo "$response"
}

# Step 4: 提交支付
submit_payment() {
    local order_id="$1"
    local csrf_token="$2"
    
    local pay_info="{\"payOrderInfos\":[{\"orderId\":\"$order_id\",\"subOrderId\":\"$order_id\",\"orderType\":\"LX\"}],\"clientEnv\":\"pc\",\"umidToken\":\"\",\"useCyberBank\":false,\"useCyberBankAmount\":\"0\"}"
    
    local response
    response=$(curl -s --max-time 10 \
        -X POST \
        -H "User-Agent: $USER_AGENT" \
        -H "Cookie: $COOKIE" \
        -H "Referer: https://cashier.aliyun.com/" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "submitPayInfo=$pay_info" \
        --data-urlencode "action=order_action" \
        --data-urlencode "event_submit_do_pay_order=submit" \
        --data-urlencode "authCode=" \
        --data-urlencode "_csrf_token=$csrf_token" \
        --data-urlencode "umidToken=" \
        --data-urlencode "collina=" \
        "https://cashier.aliyun.com/ajax/PayExternalAjax/fastPay.json" 2>&1)
    
    echo "$response"
}

# Step 5: 通过BSS API直接支付（备用路径）
bss_pay() {
    local order_id="$1"
    
    local response
    response=$(curl -s --max-time 10 \
        -X POST \
        -H "User-Agent: $USER_AGENT" \
        -H "Cookie: $COOKIE" \
        -H "Referer: $REFERER" \
        -H "Content-Type: application/json" \
        -d "{
            \"action\":\"BssOpenAPI-V3\",
            \"api\":\"MergePay\",
            \"params\":{
                \"orderId\":\"$order_id\",
                \"paymentType\":\"userbalance\",
                \"amount\":\"149.74\",
                \"extendInfo\":{},
                \"returnUrl\":\"$REFERER\"
            }
        }" \
        "https://fecs.console.aliyun.com/data/v2/multiApi.json" 2>&1)
    
    echo "$response"
}

# ===== 主抢购逻辑 =====
MAX_ROUNDS=3600  # 最多运行3600轮 (约6分钟)
INTERVAL=0.1     # 0.1秒间隔

log "开始抢购，间隔 ${INTERVAL}s，最多 ${MAX_ROUNDS} 轮"

for ((i=1; i<=MAX_ROUNDS; i++)); do
    # 每隔50轮打印一次进度
    if (( i % 50 == 0 )); then
        log "第 ${i}/${MAX_ROUNDS} 轮..."
    fi
    
    # 1. 检查库存
    inventory_resp=$(check_inventory)
    inventory_num=$(echo "$inventory_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('inventoryNum',-1))" 2>/dev/null || echo "-1")
    
    if [ "$inventory_num" = "0" ] || [ "$inventory_num" = "-1" ]; then
        # 库存为0，继续等待
        continue
    fi
    
    log "!!! 检测到库存变化: inventoryNum=$inventory_num !!!"
    
    # 2. 获取CSRF Token
    csrf_token=$(get_csrf_token)
    if [ -z "$csrf_token" ]; then
        log "WARNING: CSRF Token获取失败，继续尝试..."
        continue
    fi
    log "CSRF Token获取成功"
    
    # 3. 创建订单
    order_resp=$(create_order "$csrf_token")
    log "创建订单响应: $order_resp"
    
    order_id=$(echo "$order_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('orderId',''))" 2>/dev/null || echo "")
    
    if [ -z "$order_id" ]; then
        # 尝试从其他字段提取
        order_id=$(echo "$order_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('orderId','') or d.get('data',''))" 2>/dev/null || echo "")
    fi
    
    if [ -z "$order_id" ]; then
        log "WARNING: 订单创建失败，响应: $order_resp"
        continue
    fi
    
    log "!!! 订单创建成功: $order_id !!!"
    
    # 4. 提交支付 - 路径1
    pay_resp=$(submit_payment "$order_id" "$csrf_token")
    log "支付响应(路径1): $pay_resp"
    
    # 检查是否成功
    pay_success=$(echo "$pay_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success', d.get('code','')))" 2>/dev/null || echo "")
    
    if [ "$pay_success" = "True" ] || [ "$pay_success" = "true" ] || [ "$pay_success" = "200" ]; then
        log "========== 抢购成功！=========="
        echo "SUCCESS: $order_id" > "$STATUS_FILE"
        exit 0
    fi
    
    # 5. 备用支付路径
    bss_resp=$(bss_pay "$order_id")
    log "支付响应(路径2): $bss_resp"
    
    bss_success=$(echo "$bss_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success', d.get('code','')))" 2>/dev/null || echo "")
    
    if [ "$bss_success" = "True" ] || [ "$bss_success" = "true" ] || [ "$bss_success" = "200" ]; then
        log "========== 抢购成功（备用路径）！=========="
        echo "SUCCESS: $order_id" > "$STATUS_FILE"
        exit 0
    fi
    
    log "支付未成功，继续尝试下一轮..."
done

log "抢购脚本执行完毕，共 ${MAX_ROUNDS} 轮，未成功"
echo "FAILED: rounds exhausted" > "$STATUS_FILE"
