#!/bin/bash
# ============================================================
# 阿里百炼 Coding Plan - 接口预验证脚本
# 在抢购前10分钟运行，验证所有接口是否正常
# ============================================================

COOKIE_FILE="/home/z/my-project/download/coding-plan-grab/cookies.txt"
LOG_FILE="/home/z/my-project/download/coding-plan-grab/verify_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="/home/z/my-project/download/coding-plan-grab/purchase_status.txt"
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
REFERER="https://bailian.console.aliyun.com/cn-beijing?tab=coding-plan#/efm/coding-plan-index"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== 接口预验证启动 ==="
ERRORS=0

# 1. 检查Cookie
if [ ! -f "$COOKIE_FILE" ]; then
    log "ERROR: Cookie文件不存在！"
    echo "VERIFY_FAILED: no cookie" > "$STATUS_FILE"
    exit 1
fi
COOKIE=$(cat "$COOKIE_FILE")
log "Cookie文件存在 ($(echo "$COOKIE" | wc -c) bytes)"

# 2. 验证登录状态 - 访问百炼控制台
log "验证登录状态..."
login_resp=$(curl -s --max-time 10 \
    -H "User-Agent: $USER_AGENT" \
    -H "Cookie: $COOKIE" \
    "https://bailian.console.aliyun.com/cn-beijing/api/coding-plan/index" 2>&1)

if echo "$login_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('code') in [200, 0, '200']" 2>/dev/null; then
    log "登录状态: 有效"
else
    log "WARNING: 登录状态异常，响应: $(echo "$login_resp" | head -c 200)"
    ERRORS=$((ERRORS + 1))
fi

# 3. 检查库存状态
log "检查库存状态..."
inventory_resp=$(curl -s --max-time 10 \
    -H "User-Agent: $USER_AGENT" \
    -H "Cookie: $COOKIE" \
    -H "Referer: $REFERER" \
    "https://bailian.console.aliyun.com/cn-beijing/api/coding-plan/inventory" 2>&1)

log "库存响应: $(echo "$inventory_resp" | head -c 300)"

inventory_num=$(echo "$inventory_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('inventoryNum','unknown'))" 2>/dev/null || echo "parse_error")
log "库存数量: $inventory_num"

if [ "$inventory_num" = "0" ]; then
    log "库存: 已售罄（符合预期，等待补货）"
elif [ "$inventory_num" = "unknown" ] || [ "$inventory_num" = "parse_error" ]; then
    log "WARNING: 库存接口可能已变化，需要手动检查"
    ERRORS=$((ERRORS + 1))
else
    log "!!! 库存有货: $inventory_num，可以立即抢购！"
    echo "VERIFY_OK: IN_STOCK:$inventory_num" > "$STATUS_FILE"
fi

# 4. 验证CSRF Token接口
log "验证CSRF Token接口..."
csrf_resp=$(curl -s --max-time 10 \
    -H "User-Agent: $USER_AGENT" \
    -H "Cookie: $COOKIE" \
    -H "Referer: https://cashier.aliyun.com/" \
    "https://cashier.aliyun.com/order/ajax/payAjax/getCsrfToken.json" 2>&1)

csrf_token=$(echo "$csrf_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('_csrf_token',''))" 2>/dev/null || echo "")

if [ -n "$csrf_token" ]; then
    log "CSRF Token接口: 正常 (token: ${csrf_token:0:10}...)"
else
    log "WARNING: CSRF Token获取失败！"
    ERRORS=$((ERRORS + 1))
fi

# 5. 验证订单创建接口（试探性请求，预期因库存不足失败）
log "验证订单创建接口..."
order_resp=$(curl -s --max-time 10 \
    -X POST \
    -H "User-Agent: $USER_AGENT" \
    -H "Cookie: $COOKIE" \
    -H "Referer: $REFERER" \
    -H "Content-Type: application/json" \
    -d '{"test":"verify"}' \
    "https://bailian.console.aliyun.com/cn-beijing/api/coding-plan/createOrder" 2>&1)

if [ -n "$order_resp" ]; then
    log "订单创建接口: 可达 (响应: $(echo "$order_resp" | head -c 200))"
else
    log "WARNING: 订单创建接口无响应"
    ERRORS=$((ERRORS + 1))
fi

# 汇总
log "=== 验证完成 ==="
log "错误数: $ERRORS"

if [ $ERRORS -eq 0 ]; then
    log "所有接口正常，可以开始抢购！"
    echo "VERIFY_OK" > "$STATUS_FILE"
else
    log "存在 $ERRORS 个问题，建议手动检查"
    echo "VERIFY_WARN: $ERRORS issues" > "$STATUS_FILE"
fi
