// ============================================================
// 阿里百炼 Coding Plan Pro 本地抢购脚本
// 使用方法：
//   1. Chrome 打开 https://common-buy.aliyun.com/coding-plan
//   2. 确保已登录，选好 Coding Plan Pro、支付方式
//   3. F12 打开控制台，粘贴本脚本，回车执行
//   4. 脚本会自动等待补货并点击 Subscribe
// ============================================================

(function() {
    if (window.__grabActive) {
        console.log("[抢购] 已在运行中，不要重复执行");
        return;
    }
    window.__grabActive = true;

    var R = {
        started: true,
        phase: "monitoring",
        clicked: false,
        clickTime: null,
        logs: [],
        startTime: Date.now(),
        reloadCount: 0,
        lastReload: Date.now(),
        btnText: "",
        btnDisabled: true
    };

    function log(msg) {
        var ms = Date.now() - R.startTime;
        var timeStr = new Date().toLocaleTimeString();
        R.logs.push("[" + timeStr + " +" + ms + "ms] " + msg);
        console.log("[抢购] " + msg);
    }

    log("========================================");
    log("Coding Plan Pro 抢购脚本已启动");
    log("购买页: " + location.href);
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

            // 匹配目标按钮（售罄时文字是 "Temporarily out of stock..."，有货时变成 "Subscribe"）
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

    // ========== 点击并处理后续 ==========
    function onButtonEnabled(btn) {
        log("========================================");
        log("!!! 按钮已变为可用 !!!");
        log("按钮文字: " + btn.text);
        log("========================================");

        try {
            btn.el.click();
        } catch(e) {
            log("click() 失败: " + e.message + ", 尝试 dispatchEvent");
            try {
                btn.el.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
            } catch(e2) {
                log("dispatchEvent 也失败: " + e2.message);
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
            document.title = R.clicked ? "✅ 已点击! " + new Date().toLocaleTimeString() : document.title;
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
            attributeFilter: ["class", "disabled", "style", "aria-disabled", "data-state"]
        });
        log("MutationObserver 已启动 ✓");
    } catch(e) {
        log("MutationObserver 失败: " + e.message);
    }

    // ========== 50ms 轮询 ==========
    var mainInterval = setInterval(function() {
        if (R.clicked) {
            clearInterval(mainInterval);
            return;
        }

        var r = findSubscribeButton();
        if (!r) return;

        if (r.disabled) {
            // 每30秒自动刷新检查库存（只在售罄状态下刷新）
            var now = Date.now();
            if (now - R.lastReload > 30000) {
                R.reloadCount++;
                R.lastReload = now;
                log("按钮仍禁用 [" + r.text.substring(0, 40) + "]，刷新页面... (第" + R.reloadCount + "次)");
                location.reload();
            }
            return;
        }

        // 按钮可用！
        onButtonEnabled(r);
    }, 50);

    log("50ms 轮询已启动 ✓");
    log("等待 09:30 补货...脚本会自动刷新页面并在按钮可用时立即点击");
    log("可以在控制台输入 __grabStatus 查看状态");

    // 暴露状态查询
    window.__grabStatus = function() {
        return JSON.stringify(R, null, 2);
    };

    // 30分钟自动清理
    setTimeout(function() {
        clearInterval(mainInterval);
        try { observer.disconnect(); } catch(e) {}
        if (!R.clicked) {
            log("30分钟超时，脚本停止");
            R.phase = "timeout";
        }
    }, 1800000);
})();
