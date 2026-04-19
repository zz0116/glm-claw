// ============================================================
// 阿里百炼 Coding Plan Pro 本地抢购脚本 v5
// 
// 使用方法：
//   1. Chrome 打开 https://common-buy.aliyun.com/coding-plan
//   2. 确保已登录，选好 Coding Plan Pro、支付方式
//   3. F12 打开控制台，粘贴本脚本，回车执行
//   4. 脚本会在09:30前自动加速刷新，按钮可用时立即点击
//
// v5 优化：
//   - 轮询降到30ms（v4是50ms）
//   - fetch预热：补货前60秒开始每10秒探测服务器
//   - 智能reload加速：30s→8s→3s→0.8s
//   - MutationObserver增加data-status属性监听
//   - 多事件点击：click + PointerEvent双保险
//   - 使用location.replace()更快刷新（不留历史记录）
// ============================================================

(function() {
    if (window.__grabActive) {
        console.log("[抢购v5] 已在运行中，不要重复执行");
        return;
    }
    window.__grabActive = true;

    var RESTOCK_HOUR = 9, RESTOCK_MIN = 30;

    var R = {
        started: true,
        version: "v5",
        phase: "monitoring",
        clicked: false,
        clickTime: null,
        logs: [],
        startTime: Date.now(),
        reloadCount: 0,
        lastReload: Date.now(),
        lastPrefetch: 0,
        btnText: "",
        btnDisabled: true
    };

    function log(msg) {
        var ms = Date.now() - R.startTime;
        var timeStr = new Date().toLocaleTimeString();
        R.logs.push("[" + timeStr + " +" + ms + "ms] " + msg);
        console.log("[抢购v5] " + msg);
    }

    log("========================================");
    log("Coding Plan Pro 抢购脚本 v5 已启动");
    log("购买页: " + location.href);
    log("补货目标: " + RESTOCK_HOUR + ":" + (RESTOCK_MIN < 10 ? "0" : "") + RESTOCK_MIN);
    log("========================================");

    // ========== 查找按钮 ==========
    function findSubscribeButton() {
        var btns = document.querySelectorAll("button");
        for (var i = 0; i < btns.length; i++) {
            var b = btns[i];
            var rect = b.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            if (b.style.display === "none" || b.style.visibility === "hidden") continue;

            var t = (b.textContent || "").trim();
            if (t.indexOf("Subscribe") !== -1 ||
                t.indexOf("out of stock") !== -1 ||
                t.indexOf("暂时售罄") !== -1 ||
                t.indexOf("一次性") !== -1) {

                var dis = b.disabled || b.getAttribute("disabled") !== null;
                R.btnText = t.substring(0, 80);
                R.btnDisabled = dis;
                return { el: b, text: t, disabled: dis };
            }
        }
        return null;
    }

    // ========== 计算到补货的秒数 ==========
    function secondsToRestock() {
        var now = new Date();
        var target = new Date(now.getFullYear(), now.getMonth(), now.getDate(), RESTOCK_HOUR, RESTOCK_MIN, 0, 0);
        var diff = Math.floor((target - now) / 1000);
        return diff;
    }

    // ========== 智能reload间隔 ==========
    function getReloadInterval() {
        var s = secondsToRestock();
        if (s > 600) return 30;    // >10分钟: 30秒
        if (s > 300) return 15;    // 5-10分钟: 15秒
        if (s > 120) return 8;     // 2-5分钟: 8秒
        if (s > 30) return 3;      // 30秒-2分钟: 3秒
        if (s > -5) return 0.8;    // -5~30秒: 0.8秒（最高频率）
        return 2;                  // 已过5秒: 2秒
    }

    // ========== fetch预热 ==========
    function prefetchWarmup() {
        var now = Date.now();
        if (now - R.lastPrefetch < 10000) return; // 每10秒一次
        R.lastPrefetch = now;
        try {
            fetch(location.href, {
                method: 'HEAD',
                cache: 'no-store',
                mode: 'no-cors',
                credentials: 'include'
            }).then(function() {
                log("预热连接成功");
            }).catch(function(e) {
                log("预热: " + e.message);
            });
        } catch(e) {}
    }

    // ========== 点击并处理后续 ==========
    function onButtonEnabled(btn) {
        log("========================================");
        log("!!! 按钮已变为可用 !!!");
        log("按钮文字: " + btn.text);
        log("========================================");

        // 双保险点击
        try { btn.el.click(); } catch(e) {
            log("click() 失败: " + e.message + ", 尝试其他方法");
            try {
                btn.el.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window}));
            } catch(e2) {
                try {
                    btn.el.dispatchEvent(new PointerEvent("pointerdown", {bubbles: true, cancelable: true}));
                    btn.el.dispatchEvent(new PointerEvent("pointerup", {bubbles: true, cancelable: true}));
                } catch(e3) {}
            }
        }

        R.clicked = true;
        R.clickTime = Date.now();
        R.phase = "clicked";
        log("已点击 Subscribe！耗时: " + (Date.now() - R.startTime) + "ms");
        log("请手动完成支付确认！");

        clearInterval(mainInterval);
        try { observer.disconnect(); } catch(e) {}

        // 闪烁标题提醒
        var blink = setInterval(function() {
            document.title = "✅ 已点击! " + new Date().toLocaleTimeString();
        }, 500);
    }

    // ========== MutationObserver ==========
    var observer = new MutationObserver(function(mutations) {
        if (R.clicked) return;
        var r = findSubscribeButton();
        if (r && !r.disabled) {
            onButtonEnabled(r);
        }
    });

    try {
        observer.observe(document.body, {
            childList: true, subtree: true, attributes: true,
            attributeFilter: ["class", "disabled", "style", "aria-disabled", "data-status", "data-state", "data-soldout"]
        });
        log("MutationObserver 已启动 ✓");
    } catch(e) {
        log("MutationObserver 失败: " + e.message);
    }

    // ========== 30ms 轮询 ==========
    var mainInterval = setInterval(function() {
        if (R.clicked) {
            clearInterval(mainInterval);
            return;
        }

        var r = findSubscribeButton();
        if (!r) return;

        if (r.disabled) {
            // 智能reload
            var now = Date.now();
            var interval = getReloadInterval() * 1000;
            if (now - R.lastReload > interval) {
                R.reloadCount++;
                R.lastReload = now;
                var s = secondsToRestock();
                log("刷新页面... (第" + R.reloadCount + "次, 补货倒计时:" + s + "s, 间隔:" + Math.round(interval/1000) + "s)");
                location.replace(location.href); // 比location.reload()更快
            }
            return;
        }

        onButtonEnabled(r);
    }, 30); // v5: 30ms（v4是50ms）

    log("30ms 轮询已启动 ✓");

    // ========== 预热定时器（补货前60秒开始）==========
    var prefetchInterval = setInterval(function() {
        if (R.clicked) { clearInterval(prefetchInterval); return; }
        var s = secondsToRestock();
        if (s < 60 && s > -30) {
            prefetchWarmup();
        }
    }, 5000);

    log("预热监控已启动 ✓");
    log("等待 " + RESTOCK_HOUR + ":" + (RESTOCK_MIN < 10 ? "0" : "") + RESTOCK_MIN + " 补货...");
    log("控制台输入 __grabStatus 查看状态，__grabStop 停止");

    // 暴露控制接口
    window.__grabStatus = function() {
        var copy = Object.assign({}, R);
        copy.secondsToRestock = secondsToRestock();
        copy.nextReloadIn = Math.max(0, Math.round((getReloadInterval() * 1000 - (Date.now() - R.lastReload)) / 1000));
        return JSON.stringify(copy, null, 2);
    };
    window.__grabStop = function() {
        clearInterval(mainInterval);
        clearInterval(prefetchInterval);
        try { observer.disconnect(); } catch(e) {}
        log("脚本已手动停止");
        window.__grabActive = false;
    };

    // 30分钟自动清理
    setTimeout(function() {
        clearInterval(mainInterval);
        clearInterval(prefetchInterval);
        try { observer.disconnect(); } catch(e) {}
        if (!R.clicked) {
            log("30分钟超时，脚本停止");
            R.phase = "timeout";
        }
    }, 1800000);
})();
