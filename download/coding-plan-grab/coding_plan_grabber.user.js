// ==UserScript==
// @name         阿里百炼 Coding Plan Pro 抢购助手
// @namespace    https://common-buy.aliyun.com/
// @version      4.2
// @description  自动监控 Coding Plan Pro 库存状态，按钮可用时自动点击订阅+确认支付
// @author       zyz
// @match        https://common-buy.aliyun.com/coding-plan*
// @match        https://common-buy.aliyun.com/?commodityCode=sfm_platform_public_cn*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function() {
    'use strict';

    // ============================================================
    // 配置区
    // ============================================================
    var CONFIG = {
        pollInterval: 50,         // 轮询间隔（毫秒），50ms = 每秒20次
        reloadInterval: 15000,    // 售罄状态下自动刷新间隔（毫秒）
        enableAutoReload: true,   // 是否自动刷新页面检查库存
        enableAutoConfirm: true,  // 是否自动点击确认/支付按钮
        enableAutoPayment: true,  // 是否自动选择余额支付并点击支付确认
        maxRuntime: 30 * 60 * 1000, // 最大运行时间（毫秒），30分钟
        soundAlert: true,         // 成功时是否播放提示音
    };

    // ============================================================
    // 状态对象
    // ============================================================
    var R = {
        started: true,
        phase: "init",
        clicked: false,
        confirmed: false,
        payDone: false,
        clickTime: null,
        logs: [],
        startTime: Date.now(),
        reloadCount: 0,
        lastReload: Date.now(),
        btnText: "",
        btnDisabled: true,
        url: location.href
    };

    function log(msg) {
        var ms = Date.now() - R.startTime;
        var time = new Date().toLocaleTimeString();
        var entry = "[" + time + " +" + ms + "ms] " + msg;
        R.logs.push(entry);
        if (R.logs.length > 500) R.logs.shift();
        console.log("[抢购助手] " + entry);

        // 在页面右上角显示状态
        updateStatusDisplay();
    }

    // ============================================================
    // 页面状态显示（浮动小窗）
    // ============================================================
    function createStatusDisplay() {
        var el = document.createElement("div");
        el.id = "__grab_status_panel";
        el.innerHTML = '<div style="position:fixed;top:10px;right:10px;z-index:99999;background:rgba(0,0,0,0.85);color:#0f0;padding:10px 14px;border-radius:8px;font:12px/1.6 monospace;min-width:220px;box-shadow:0 2px 12px rgba(0,0,0,0.5);cursor:move;" id="__grab_inner">' +
            '<div style="color:#ff0;font-weight:bold;margin-bottom:4px;">🤖 Coding Plan 抢购助手 v4.2</div>' +
            '<div id="__grab_status_text">启动中...</div>' +
            '<div id="__grab_btn_status" style="margin-top:4px;color:#aaa;"></div>' +
            '<div id="__grab_reload_info" style="margin-top:2px;color:#666;"></div>' +
            '</div>';
        document.body.appendChild(el);

        // 可拖动
        var inner = document.getElementById("__grab_inner");
        var dragging = false, offsetX = 0, offsetY = 0;
        inner.addEventListener("mousedown", function(e) {
            dragging = true;
            offsetX = e.clientX - inner.offsetLeft;
            offsetY = e.clientY - inner.offsetTop;
            e.preventDefault();
        });
        document.addEventListener("mousemove", function(e) {
            if (!dragging) return;
            inner.style.left = (e.clientX - offsetX) + "px";
            inner.style.top = (e.clientY - offsetY) + "px";
        });
        document.addEventListener("mouseup", function() { dragging = false; });
    }

    function updateStatusDisplay() {
        var statusEl = document.getElementById("__grab_status_text");
        var btnEl = document.getElementById("__grab_btn_status");
        var reloadEl = document.getElementById("__grab_reload_info");

        if (!statusEl) return;

        var phaseText = {
            "init": "⏳ 初始化中",
            "monitoring": "👀 监控中 - 等待补货",
            "clicked": "✅ 已点击 Subscribe!",
            "confirmed": "✅ 已确认订单!",
            "payment_page": "💳 处理支付中...",
            "payment_done": "🎉 支付完成!",
            "timeout": "⏰ 超时停止"
        };

        statusEl.textContent = phaseText[R.phase] || R.phase;
        if (R.clicked) {
            statusEl.style.color = "#0f0";
        } else if (R.phase === "timeout") {
            statusEl.style.color = "#f00";
        }

        if (btnEl) {
            btnEl.textContent = R.btnDisabled ? "按钮: " + R.btnText.substring(0, 30) + " [禁用]" : "按钮: " + R.btnText.substring(0, 30) + " [可用!]";
            btnEl.style.color = R.btnDisabled ? "#f88" : "#0f0";
        }

        if (reloadEl) {
            var timeToRestock = getTimeToRestock();
            if (timeToRestock !== null) {
                reloadEl.textContent = "下次刷新: " + Math.max(0, timeToRestock) + "s | 已刷新: " + R.reloadCount + "次";
            }
        }
    }

    function getTimeToRestock() {
        // 从页面文字提取补货时间
        var text = document.body.innerText;
        // 匹配 "restocking at 04/19 01:30" 或 "补货时间" 等
        var match = text.match(/restocking at (\d{2}\/\d{2}\s+\d{2}:\d{2})/i);
        if (match) {
            var parts = match[1].split(/[\s\/:]+/);
            var now = new Date();
            var restockDate = new Date(now.getFullYear(), parseInt(parts[0]) - 1, parseInt(parts[1]),
                                       parseInt(parts[2]), parseInt(parts[3]));
            var diff = Math.floor((restockDate.getTime() - Date.now()) / 1000);
            return diff;
        }
        return null;
    }

    // ============================================================
    // 核心函数
    // ============================================================

    // 查找购买按钮
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

    // 查找并点击确认按钮（Subscribe点击后的确认页）
    function findAndClickConfirm() {
        if (!CONFIG.enableAutoConfirm) return false;

        var allEls = document.querySelectorAll("button, a, [role=button], input[type=submit]");
        var kws = ["确认", "提交", "立即购买", "Subscribe", "Confirm", "Submit", "创建订单", "下一步"];

        for (var i = 0; i < allEls.length; i++) {
            var el = allEls[i];
            var rect = el.getBoundingClientRect();
            if (rect.width === 0) continue;
            if (el.disabled || el.style.display === "none" || el.style.pointerEvents === "none") continue;

            var text = (el.textContent || el.value || "").trim();
            for (var j = 0; j < kws.length; j++) {
                if (text.indexOf(kws[j]) !== -1 && text.length < 25) {
                    log("找到确认按钮: [" + text + "]");
                    el.click();
                    return true;
                }
            }
        }
        return false;
    }

    // 查找并点击支付按钮
    function findAndClickPay() {
        if (!CONFIG.enableAutoPayment) return false;

        // 先尝试选余额支付
        var labels = document.querySelectorAll("label, div[onclick], span");
        for (var i = 0; i < labels.length; i++) {
            var lt = (labels[i].textContent || "").trim();
            if (lt.indexOf("余额") !== -1 && lt.indexOf("支付宝") === -1) {
                labels[i].click();
                log("已选择余额支付");
                break;
            }
        }

        // 点击支付确认按钮
        var payBtns = document.querySelectorAll("button, a, [role=button], input[type=submit]");
        var payKws = ["确认支付", "去支付", "立即支付", "确认付款", "Pay", "Confirm", "Submit"];
        for (var j = 0; j < payBtns.length; j++) {
            var pb = payBtns[j];
            if (pb.disabled || pb.style.display === "none") continue;
            var pt = (pb.textContent || pb.value || "").trim();
            for (var k = 0; k < payKws.length; k++) {
                if (pt.indexOf(payKws[k]) !== -1) {
                    log("点击支付按钮: [" + pt + "]");
                    pb.click();
                    return true;
                }
            }
        }
        return false;
    }

    // 点击成功后的处理流程
    function handleAfterClick() {
        R.phase = "post_click";
        log("等待页面跳转（自动确认+支付）...");

        var postIv = setInterval(function() {
            var url = location.href;

            // 检测到支付/订单页面
            if (url.indexOf("cashier") !== -1 || url.indexOf("pay") !== -1 ||
                url.indexOf("order") !== -1 || url.indexOf("success") !== -1 ||
                url.indexOf("trade") !== -1) {

                log("检测到支付/订单页面: " + url);
                R.phase = "payment_page";
                clearInterval(postIv);

                setTimeout(function() {
                    if (findAndClickPay()) {
                        R.payDone = true;
                        R.phase = "payment_done";
                        log("🎉 支付流程已触发！请确认支付结果");
                        playAlert();
                    }
                }, 500);
                return;
            }

            // 检查当前页面是否有确认按钮（可能弹出确认对话框）
            if (findAndClickConfirm()) {
                R.confirmed = true;
                R.phase = "confirmed";
                log("确认按钮已点击");
                clearInterval(postIv);

                // 等跳转
                setTimeout(function() {
                    handleAfterClick(); // 继续等待
                }, 1000);
                return;
            }

            // 3秒检测一次，最多检测2分钟
        }, 500);

        // 2分钟超时
        setTimeout(function() {
            clearInterval(postIv);
            if (!R.confirmed && !R.payDone) {
                log("后续处理超时，但 Subscribe 已点击，请手动确认");
            }
        }, 120000);
    }

    // 播放提示音
    function playAlert() {
        if (!CONFIG.soundAlert) return;
        try {
            var ctx = new (window.AudioContext || window.webkitAudioContext)();
            var osc = ctx.createOscillator();
            var gain = ctx.createGain();
            osc.connect(gain);
            gain.connect(ctx.destination);
            osc.frequency.value = 800;
            gain.gain.value = 0.3;
            osc.start();
            setTimeout(function() {
                osc.frequency.value = 1200;
            }, 200);
            setTimeout(function() {
                osc.stop();
                ctx.close();
            }, 500);
        } catch(e) {
            // 静默失败
        }
    }

    // ============================================================
    // 主流程
    // ============================================================
    log("========================================");
    log("Coding Plan Pro 抢购助手 v4.2 已启动");
    log("购买页: " + location.href);
    log("轮询间隔: " + CONFIG.pollInterval + "ms");
    log("自动刷新: " + (CONFIG.enableAutoReload ? "开启" : "关闭"));
    log("自动确认: " + (CONFIG.enableAutoConfirm ? "开启" : "关闭"));
    log("自动支付: " + (CONFIG.enableAutoPayment ? "开启" : "关闭"));
    log("========================================");

    createStatusDisplay();
    R.phase = "monitoring";

    // MutationObserver - 监听DOM变化
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

    // 50ms 轮询
    var mainInterval = setInterval(function() {
        if (R.clicked) { clearInterval(mainInterval); return; }

        var r = findSubscribeButton();
        if (!r) return;

        if (r.disabled) {
            // 售罄状态 - 自动刷新
            if (CONFIG.enableAutoReload) {
                var now = Date.now();
                if (now - R.lastReload > CONFIG.reloadInterval) {
                    R.reloadCount++;
                    R.lastReload = now;
                    log("按钮仍禁用，刷新页面检查库存 (第" + R.reloadCount + "次)...");
                    location.reload();
                }
            }
            return;
        }

        // 按钮可用！
        onButtonEnabled(r);
    }, CONFIG.pollInterval);

    function onButtonEnabled(btn) {
        log("========================================");
        log("!!! 按钮已变为可用 !!!");
        log("按钮文字: " + btn.text);
        log("响应耗时: " + (Date.now() - R.startTime) + "ms");
        log("========================================");

        try { btn.el.click(); } catch(e) {
            log("click() 失败，尝试 dispatchEvent");
            try { btn.el.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true})); } catch(e2) {}
        }

        R.clicked = true;
        R.clickTime = Date.now();
        R.phase = "clicked";

        clearInterval(mainInterval);
        try { observer.disconnect(); } catch(e) {}

        playAlert();

        // 延迟1秒再处理后续（给页面跳转时间）
        setTimeout(handleAfterClick, 1000);
    }

    // 暴露状态查询（控制台用）
    window.__grabStatus = function() { return JSON.stringify(R, null, 2); };
    window.__grabLogs = function() { return R.logs.join("\n"); };
    window.__grabStop = function() {
        clearInterval(mainInterval);
        try { observer.disconnect(); } catch(e) {}
        R.phase = "stopped";
        log("手动停止");
    };

    log("50ms 轮询已启动 ✓");
    log("页面右上角显示实时状态 | 控制台输入 __grabStatus() 查看详情");

    // 超时自动停止
    setTimeout(function() {
        clearInterval(mainInterval);
        try { observer.disconnect(); } catch(e) {}
        if (!R.clicked) {
            log(CONFIG.maxRuntime / 60000 + "分钟超时，脚本停止");
            R.phase = "timeout";
        }
    }, CONFIG.maxRuntime);
})();
