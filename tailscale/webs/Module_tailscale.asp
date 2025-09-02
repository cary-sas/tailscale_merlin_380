<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <meta HTTP-EQUIV="Pragma" CONTENT="no-cache"/>
  <meta HTTP-EQUIV="Expires" CONTENT="-1"/>
  <link rel="shortcut icon" href="images/favicon.png"/>
  <link rel="icon" href="images/favicon.png"/>
  <title>软件中心 - Tailscale</title>
  <link rel="stylesheet" type="text/css" href="index_style.css"/>
  <link rel="stylesheet" type="text/css" href="form_style.css"/>
  <link rel="stylesheet" type="text/css" href="css/element.css"/>
  <script type="text/javascript" src="/state.js"></script>  
  <script type="text/javascript" src="/popup.js"></script>
  <script type="text/javascript" src="/help.js"></script>
  <script type="text/javascript" src="/validator.js"></script>
  <script type="text/javascript" src="/js/jquery.js"></script>
  <script type="text/javascript" src="/general.js"></script>
  <script type="text/javascript" src="/switcherplugin/jquery.iphone-switch.js"></script>
  <!-- inject dbus variables under db_tailscale[...] -->
  <script type="text/javascript" src="/dbconf?p=tailscale&v=<% uptime(); %>"></script>
  
  <script>
/* ================== 通用小工具 ================== */
function E(id){ return document.getElementById(id); }

/* 这些全局变量与参考实现一致，用于实时日志 */
var _responseLen = 0;
var noChange = 0;
var x = 5; // 倒计时
var _ts_polling = false;
var _popup_mode = 'submit';

/* ---------- 关键：覆盖 state.js 的 show_loading_obj() ---------- */
(function patchStateLoading(){
  var _orig = window.show_loading_obj;
  window.show_loading_obj = function(){
    // 先执行原函数，生成那段包含 loading.gif 的条
    if (typeof _orig === 'function') _orig();

    // 立即隐藏之（参考项目里效果就是这样避免与自家弹窗冲突）
    hideGlobalLoading();
  };
})();

/* ================== 页面初始化 ================== */
function switchType(obj, show) { obj.type = show ? 'text' : 'password'; }

function init() {
  show_menu(menu_hook);
  buildswitches();
  conf2obj();
  hideGlobalLoading();   // 页面就绪时再兜底隐藏一次“请稍候”条
}

function menu_hook() {
  tabtitle[tabtitle.length - 1] = new Array("", "tailscale");
  tablink[tablink.length - 1]  = new Array("", "Module_tailscale.asp");
}

function buildswitches() {
  // master enable switch -> hidden input
  $("#switch_enable").on("click", function(){
    document.form.tailscale_enable.value = this.checked ? 1 : 0;
  });
  // checkboxes -> hidden 0/1
  $("#cb_ipv4").on("click", function(){ document.form.tailscale_ipv4_enable.value = this.checked ? 1 : 0; });
  $("#cb_ipv6").on("click", function(){ document.form.tailscale_ipv6_enable.value = this.checked ? 1 : 0; });
//  $("#cb_accept_routes").on("click", function(){ document.form.tailscale_accept_routes.value = this.checked ? 1 : 0; });
  $("#cb_adv_exit").on("click", function(){ document.form.tailscale_advertise_exit.value = this.checked ? 1 : 0; });
  $("#cb_snat_enable").on("click", function(){ document.form.tailscale_SNAT_enable.value = this.checked ? 1 : 0; });
  
  // 角色选择 -> 同步到 hidden，并刷新 UI
  $("#sel_role").on("change", function(){
    var v = this.value;                            // "1"|"2"|"3"
    document.form.tailscale_role.value = v;        // **写回 hidden**
    updateRoleUI();
  });

  // 私有化: checkbox -> hidden；文本框 -> hidden
  $("#cb_private_enable").on("click", function(){
    document.form.tailscale_private_enable.value = this.checked ? 1 : 0;
    // 启用/禁用输入框
    E("input_login_server").disabled = !this.checked;
  });
  $("#input_login_server").on("input", function(){
    document.form.tailscale_login_server.value = (this.value || "").trim();
  });

}

function conf2obj() {
  var d = window.db_tailscale || {};
  // switches
  var en = (d["tailscale_enable"] == "1");
  E("switch_enable").checked = en;
  document.form.tailscale_enable.value = en ? 1 : 0;

  var v4 = (d["tailscale_ipv4_enable"] || "1") == "1";
  var v6 = (d["tailscale_ipv6_enable"] || "1") == "1";
  E("cb_ipv4").checked = v4;
  E("cb_ipv6").checked = v6;
  document.form.tailscale_ipv4_enable.value = v4 ? 1 : 0;
  document.form.tailscale_ipv6_enable.value = v6 ? 1 : 0;

//  var acc = (d["tailscale_accept_routes"] || "1") == "1";
//  E("cb_accept_routes").checked = acc;
//  document.form.tailscale_accept_routes.value = acc ? 1 : 0;

  var ex = (d["tailscale_advertise_exit"] || "0") == "1";
  E("cb_adv_exit").checked = ex;
  document.form.tailscale_advertise_exit.value = ex ? 1 : 0;

  // 私有化（Headscale）
  var pvt = (d["tailscale_private_enable"] || "0") == "1";
  var lsu = (d["tailscale_login_server"] || "").trim();

  E("cb_private_enable").checked = pvt;
  document.form.tailscale_private_enable.value = pvt ? 1 : 0;

  E("input_login_server").value = lsu;
  document.form.tailscale_login_server.value = lsu;
  E("input_login_server").disabled = !pvt;


// Auth Key：只从 dbus 拿值，避免依赖 input 缓存
  var akInput = E("tailscale_authkey");
  var raw = (d["tailscale_authkey"] || "").trim();

  if (raw) {
    try {
      akInput.value = atob(raw);   // 如果是 Base64，解码填进去（密码框会显示星号）
    } catch (e) {
      akInput.value = raw;         // 如果不是 Base64，就当明文
    }
  } else {
    akInput.value = "";
  }
  akInput.placeholder = akInput.value ? "" : "tskey-...";
  // 保存一份原始值，用于提交时兜底
  akInput.setAttribute("data-b64", raw);
  
  
  E("tailscale_advertise_routes").value = d["tailscale_advertise_routes"] || "";
  
  var sn = (d["tailscale_SNAT_enable"] || "1") == "1";
  E("cb_snat_enable").checked = sn;
  document.form.tailscale_SNAT_enable.value = sn ? 1 : 0;

  // 依赖：未配置广播网段则禁用 SNAT；勾选 Exit Node 时也禁用
  var hasRoutes = !!(d["tailscale_advertise_routes"] || "").trim();
  var isExit = (d["tailscale_advertise_exit"] || "0") == "1";
  E("cb_snat_enable").disabled = (!hasRoutes || isExit);
  
  // 角色：严格按 DBus 显示；若 DBus 没值，则保留当前下拉框值（不写默认）
  var roleSaved = (d["tailscale_role"] || "").trim();
  if (roleSaved === "1" || roleSaved === "2" || roleSaved === "3") {
    E("sel_role").value = roleSaved;
    document.form.tailscale_role.value = roleSaved;
  } else {
    // DBus 没值：使用下拉框当前值，并同步到 hidden，但不强行默认 1
    var cur = E("sel_role").value || "2"; // UI 没初始化时，宁可显示“终端”也不要误成网关
    document.form.tailscale_role.value = cur;
  }
  updateRoleUI();

}

function updateRoleUI(){
  var role = document.form.tailscale_role.value; // "1"|"2"|"3"
  var isClientOnly = (role === "2");             // 终端=仅客户端

  // 终端：禁用子网路由与 SNAT（UI）
  E("tailscale_advertise_routes").disabled = isClientOnly;
  // 如果你保留了“接受其它路由”的复选框，这里也应该禁用：
  var acc = E("cb_accept_routes");
  if (acc) acc.disabled = false; // 终端仍需 accept-routes，不能禁。若你已移除可忽略。

  E("cb_snat_enable").disabled = isClientOnly;

  // 视觉淡化（可选）
  var td = E("tailscale_advertise_routes") && E("tailscale_advertise_routes").parentNode;
  if (td && td.style) td.style.opacity = isClientOnly ? .7 : 1;
}


/* ================== 提交与实时日志（参考实现同款） ================== */

// 触发后台任务并在成功回调后打开黑框与日志轮询（对齐参考例子）
function push_data(obj) {
  $.ajax({
    type: "POST",
    url: '/applydb.cgi?p=tailscale',
    contentType: "application/x-www-form-urlencoded",
    dataType: 'text',
    data: $.param(obj),
    success: function() {
      showSSLoadingBar();          // 由 popup.js 或本页兜底
      noChange = 0;
      _responseLen = 0;
      setTimeout(get_realtime_log, 500);
    }
  });
}

// 普通日志拉取（如果有“查看日志”之类再用）
function get_log() {
  $.ajax({
    url: '/cmdRet_check.htm',
    dataType: 'html',
    error: function(){ setTimeout(get_log, 1000); },
    success: function(response) {
      var retArea = E("log_content1");
      if (!retArea) return;
      if (response.search("XU6J03M6") != -1) {
        retArea.value = response.replace(/XU6J03M6/g, " ");
        return true;
      }
      if (_responseLen == response.length) noChange++; else noChange = 0;
      if (noChange > 5) return false;
      setTimeout(get_log, 200);
      retArea.value = response;
      _responseLen = response.length;
    }
  });
}

// 实时日志拉取（严格照参考例子）
function get_realtime_log() {
  if (_ts_polling) return;
  _ts_polling = true;
  _responseLen = 0;
  noChange = 0;

  function poll(){
    $.ajax({
      url: '/cmdRet_check.htm',
      dataType: 'html',
      success: function(response){
        var retArea = E("log_content3");
        var okDiv   = E("ok_button");
        if (!retArea) { _ts_polling = false; return; }

        var done = (response.indexOf("XU6J03M6") !== -1);
        var text = response.replace(/XU6J03M6/g, " ");

        retArea.value = text;
        retArea.scrollTop = retArea.scrollHeight;

		if (done){
		  if (_popup_mode === 'submit') {
			// 提交场景：显示“自动关闭（5）”
			$("#ok_button_submit").show();
			$("#ok_button_status").hide();
			x = 5;
			count_down_close();
		  } else {
			// 查看状态 / 网络检测：显示“返回主界面”
			$("#ok_button_submit").hide();
			$("#ok_button_status").show();
			// 状态场景不需要倒计时
		  }
		  _ts_polling = false;
		  return;
		}

        if (_responseLen == response.length) noChange++; else noChange = 0;
        _responseLen = response.length;

        if (noChange > 1000) { _ts_polling = false; return; }
        setTimeout(poll, 250);
      },
      error: function(){ setTimeout(poll, 500); }
    });
  }
  setTimeout(poll, 250);
}

/* ================== 黑框显隐：严格对齐参考项目 ================== */

// 先把“请稍候”条彻底关掉（参考项目：hideLoading + proceeding_* 节点）
/* ---------- 兜底：一键隐藏“请稍候”条及其 GIF ---------- */
function hideGlobalLoading(){
  // 这些 id/结构来自 state.js：loadingBlock 表格、span 提示、以及其中的 img[src*=loading.gif]
  try {
    var blk = document.getElementById('loadingBlock');
    if (blk) { blk.style.display = 'none'; blk.style.visibility = 'hidden'; }

    var t1 = document.getElementById('proceeding_main_txt');
    if (t1) { t1.style.display = 'none'; t1.style.visibility = 'hidden'; }

    var t2 = document.getElementById('proceeding_txt');
    if (t2) { t2.style.display = 'none'; t2.style.visibility = 'hidden'; }

    var gif = blk ? blk.querySelector('img[src*="loading.gif"]') : null;
    if (gif) gif.style.display = 'none';
  } catch(e){}

  // 如果被嵌在 frame 里，也顺手处理父页面（与参考项目一致的做法）
  try {
    var pdoc = parent && parent.document;
    if (pdoc && pdoc.getElementById) {
      var pblk = pdoc.getElementById('loadingBlock');
      if (pblk) { pblk.style.display = 'none'; pblk.style.visibility = 'hidden'; }
      var pt1 = pdoc.getElementById('proceeding_main_txt');
      if (pt1) { pt1.style.display = 'none'; pt1.style.visibility = 'hidden'; }
      var pt2 = pdoc.getElementById('proceeding_txt');
      if (pt2) { pt2.style.display = 'none'; pt2.style.visibility = 'hidden'; }
      var pgif = pblk ? pblk.querySelector('img[src*="loading.gif"]') : null;
      if (pgif) pgif.style.display = 'none';
    }
  } catch(e){}
}

/* ---------- 轻量监听：若系统又插回 loading.gif，立刻隐藏 ---------- */
(function autoHideAgain(){
  try{
    var mo = new MutationObserver(function(){
      var blk = document.getElementById('loadingBlock');
      if (blk && getComputedStyle(blk).display !== 'none') {
        hideGlobalLoading();
      }
    });
    mo.observe(document.body, {childList:true, subtree:true});
  }catch(e){}
})();

// 缓存 popup.js 的原函数，按参考项目风格“包一层”
var _popup_showSS = window.showSSLoadingBar || null;
var _popup_hideSS = window.hideSSLoadingBar || null;

// 统一对外：先关闭“请稍候”，再调用原函数；若无原函数，用本页兜底实现
function showSSLoadingBar(title, tips){
  // 避免被“请稍候”条遮挡：先关它（这一步是关键）
  hideGlobalLoading();

  var bar = E('LoadingBar');
  var bg  = E('Loading');
  var ta  = E('log_content3');
  var ok  = E('ok_button');
  var ok1 = E('ok_button1');

  if (title) E('loading_block3').innerHTML = title;
  if (tips)  E('loading_block2').innerHTML = tips;

  if (bg)  { bg.style.display = '';  bg.style.visibility = 'visible'; }
  if (bar) { bar.style.display = ''; bar.style.visibility = 'visible'; }

  if (ok)  ok.style.display  = 'none';
  if (ok1) ok1.value = '自动关闭（5）';

  if (ta)  ta.value = '';
  x = 5;
}

function hideSSLoadingBar(){
  var bar = E('LoadingBar');
  var bg  = E('Loading');
  if (bar) { bar.style.display = 'none'; bar.style.visibility = 'hidden'; }
  if (bg)  { bg.style.display  = 'none'; bg.style.visibility  = 'hidden'; }
}

/* ================== 倒计时（单按钮样式转换） ================== */
function count_down_close(){
  var btn = E("ok_button1");
  if (!btn) return;
  if (x === 0) { hideSSLoadingBar(); return; }
  if (x < 0) { btn.value = "手动关闭"; return; }
  btn.value = "自动关闭（" + x + "）";
  --x;
  setTimeout(count_down_close, 1000);
}
// 点击任何黑框区域 -> 切换为“手动关闭”
$(function(){
  $("#LoadingBar, #log_content2, #log_content3").on("click", function(){
    x = -1;
    var btn = E("ok_button1");
    if (btn) btn.value = "手动关闭";
  });
});


/* ================== 业务：提交按钮与快捷动作 ================== */

function onSubmitCtrl(btn, s){
  _popup_mode = 'submit';
  
  // base64 authkey
  var akEl = E("tailscale_authkey");
  var akPlain = (akEl.value || "").trim();

  var payload = {
    current_page: "Module_tailscale.asp",
    next_page: "Module_tailscale.asp",
    action_mode: " Refresh ",
    action_script: "",
    action_wait: "",
    group_id: "",
    modified: 0,
    first_time: "",
    preferred_lang: E("preferred_lang").value || "",
    firmver: "<% nvram_get(\"firmver\"); %>",
    SystemCmd: "tailscale_config",

    // dbus 同步
    tailscale_enable:           document.form.tailscale_enable.value,
    tailscale_ipv4_enable:      document.form.tailscale_ipv4_enable.value,
    tailscale_ipv6_enable:      document.form.tailscale_ipv6_enable.value,
//    tailscale_accept_routes:    document.form.tailscale_accept_routes.value,
    tailscale_advertise_exit:   document.form.tailscale_advertise_exit.value,
	  tailscale_role:            (document.form.tailscale_role && document.form.tailscale_role.value) ? document.form.tailscale_role.value : "",
	  tailscale_SNAT_enable:      document.form.tailscale_SNAT_enable.value,
    tailscale_advertise_routes: E("tailscale_advertise_routes").value || "",
    tailscale_private_enable:   document.form.tailscale_private_enable.value,
    tailscale_login_server:     document.form.tailscale_login_server.value
  };

 // 关键：只有输入非空时才覆盖原有 authkey
  if (akPlain) {
    try { payload.tailscale_authkey = btoa(akPlain); }
    catch(e){ /* 忽略错误 */ }
  }
  // 如果是空的，就完全跳过，让后端保留原有值


  // —— 根据开启/关闭 设置黑框文案（照参考项目风格）——
  var enabling = (payload.tailscale_enable == "1");
  var titleHTML = enabling ? 'Tailscale 启用中 ...' : 'Tailscale 关闭中 ...';
  var tipsHTML  = enabling
    ? '<li><font color="#ffcc00">请等待日志显示完毕，并出现自动关闭按钮！</font></li>'
      + '<li><font color="#ffcc00">此期间请不要刷新本页面！</font></li>'
    : '<li><font color="#ffcc00">请勿刷新本页面，执行中 ...</font></li>';

    if (payload.tailscale_private_enable == "1") {
      var url = (payload.tailscale_login_server || "").trim();
      if (!url) {
        alert("已勾选“私有化部署”，但未填写控制平面 URL（--login-server）。");
        return false;
      }
    }

  showSSLoadingBar(titleHTML, tipsHTML);

  // 发送并开始轮询（保持参考项目时序：先 show，再拉日志）
  $.ajax({
    type: "POST",
    url: '/applydb.cgi?p=tailscale',
    contentType: "application/x-www-form-urlencoded",
    dataType: 'text',
    data: $.param(payload),
    success: function() { get_realtime_log(); }
  });

  if (btn && btn.preventDefault) btn.preventDefault();
  return false;
}

function post_simple_cmd(cmd){
  push_data({
    current_page: "Module_tailscale.asp",
    next_page: "Module_tailscale.asp",
    action_mode: " Refresh ",
    SystemCmd: cmd
  });
}

function open_status(){
_popup_mode = 'status';
  post_simple_cmd("tailscale_status");
  $("#ok_button_submit").hide();
  $("#ok_button_status").show();
}

function open_netcheck(){
_popup_mode = 'status';
  post_simple_cmd("tailscale_ncheck");
  $("#ok_button_submit").hide();
  $("#ok_button_status").show();
}

function close_proc_status(){
  hideSSLoadingBar();
}

/* 预留的“检查并更新”逻辑（未来接 GitHub 仓库对比最新版本后再启用）
function ts_check_update(){
  // TODO: 拉取你 GitHub 仓库中的最新版本号进行比较
  // 例如：fetch('https://raw.githubusercontent.com/<owner>/<repo>/main/version.txt')
  //   .then(res => res.text())
  //   .then(latest => { 对比 <% dbus_get_def("tailscale_version","未知"); %> 后给出提示/按钮 })
  //   .catch(() => { alert('检查更新失败，请稍后再试'); });
}
*/


/* ====== Tailscale 调试辅助（仅用于排查，可留着）====== */
/*
(function(){
  var TSDBG = window.TSDBG = { polls: 0, lastLen: 0, lastHasSentinel: false };
  function dbg(){ try{ console.log('[tailscale]', new Date().toISOString(), ...arguments);}catch(e){} }

  window.__ts_checkDom = function(){
    var ids = ["Loading","LoadingBar","log_content3","ok_button","ok_button1","cmdBtn"];
    ids.forEach(function(id){
      var el = document.getElementById(id);
      dbg('DOM', id, !!el ? 'FOUND' : 'MISSING');
      if (el) {
        var cs = window.getComputedStyle(el);
        dbg('DOM', id, 'display=', cs.display, 'visibility=', cs.visibility, 'zIndex=', cs.zIndex || el.style.zIndex || '(none)');
      }
    });
  };

  window.__ts_probeCmdRet = function(){
    dbg('probe /cmdRet_check.htm (once)');
    $.ajax({
      url: '/cmdRet_check.htm',
      dataType: 'html',
      success: function(resp){
        var hasSentinel = resp && resp.indexOf('XU6J03M6') !== -1;
        dbg('probe ok: len=', resp ? resp.length : 0, 'hasSentinel=', hasSentinel);
        if (resp) {
          var head = resp.slice(0, 120).replace(/\n/g,'⏎');
          var tail = resp.slice(-120).replace(/\n/g,'⏎');
          dbg('probe head=', head);
          dbg('probe tail=', tail);
        }
      },
      error: function(xhr){ dbg('probe error', xhr && xhr.status, xhr && xhr.statusText); }
    });
  };

  if (typeof window.get_realtime_log === 'function') {
    var _orig_rt = window.get_realtime_log;
    window.get_realtime_log = function(){
      dbg('get_realtime_log() poll start, polls=', TSDBG.polls);
      var _ajax = $.ajax;
      $.ajax = function(opt){
        var userSucc = opt && opt.success;
        var userErr  = opt && opt.error;
        if (opt && opt.url === '/cmdRet_check.htm') {
          opt.success = function(resp){
            TSDBG.polls++;
            var hasSentinel = resp && resp.indexOf('XU6J03M6') !== -1;
            var len = resp ? resp.length : 0;
            if (TSDBG.polls % 10 === 1 || hasSentinel !== TSDBG.lastHasSentinel || len !== TSDBG.lastLen) {
              dbg('poll ok', 'len=', len, 'hasSentinel=', hasSentinel, 'polls=', TSDBG.polls);
              if (resp) { dbg('poll tail=', resp.slice(-120).replace(/\n/g,'⏎')); }
              TSDBG.lastHasSentinel = hasSentinel;
              TSDBG.lastLen = len;
            }
            userSucc && userSucc.apply(this, arguments);
            $.ajax = _ajax;
          };
          opt.error = function(){
            dbg('poll error', arguments && arguments[0] && arguments[0].status);
            userErr && userErr.apply(this, arguments);
            $.ajax = _ajax;
          };
        }
        return _ajax.apply(this, arguments);
      };
      return _orig_rt.apply(this, arguments);
    };
  }

  if (typeof window.onSubmitCtrl === 'function') {
    var _orig_submit = window.onSubmitCtrl;
    window.onSubmitCtrl = function(btn, s){
      dbg('onSubmitCtrl() called, s=', s);
      return _orig_submit.apply(this, arguments);
    };
  }

  if (typeof window.init === 'function') {
    var _orig_init = window.init;
    window.init = function(){
      dbg('init()');
      var r = _orig_init.apply(this, arguments);
      setTimeout(__ts_checkDom, 0);
      return r;
    };
  } else {
    setTimeout(__ts_checkDom, 1000);
  }
})();  */
</script>


</head>

<body onload="init();">
  <div id="TopBanner"></div>

<!-- Realtime log window START (copied from reference, adapted) -->
<div id="Loading" class="popup_bg" style="display:none;"></div>

<div id="LoadingBar" class="popup_bar_bg" style="display:none;">
  <table cellpadding="5" cellspacing="0" id="loadingBarBlock" class="loadingBarBlock" align="center"
         style="margin:60px auto 0 auto; width:770px;">
    <tr>
      <td height="100">
        <div id="loading_block3" style="margin:10px auto;margin-left:10px;width:85%; font-size:12pt;">Tailscale 执行中 ...</div>
        <div id="loading_block2" style="margin:10px auto;width:95%;">
          <li><font color="#ffcc00">请勿刷新本页面，执行中 ...</font></li>
        </div>

        <div id="log_content2" style="margin-left:15px;margin-right:15px;margin-top:10px;overflow:hidden">
          <textarea cols="63" rows="27" wrap="on" readonly="readonly" id="log_content3"
            autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
            style="border:1px solid #000;width:99%; font-family:'Lucida Console'; font-size:11px;
                   background:#000;color:#FFFFFF;outline: none;padding-left:3px;padding-right:22px;overflow-x:hidden"></textarea>
        </div>

		<!-- 提交操作的按钮 -->
		<div id="ok_button_submit" class="apply_gen" style="background:#000; display:none; margin-top:5px; padding-bottom:10px; width:100%; text-align:center;">
		  <input id="ok_button1" class="button_gen" type="button" onclick="hideSSLoadingBar()" value="自动关闭（5）">
		</div>

		<!-- 查看状态 / 网络检测 的按钮 -->
		<div id="ok_button_status" class="apply_gen" style="background:#000; display:none; margin-top:5px; padding-bottom:10px; width:100%; text-align:center;">
		  <input class="button_gen" type="button" onclick="close_proc_status();" value="返回主界面">
		</div>		
		
      </td>
    </tr>
  </table>
</div>
<!-- Realtime log window END -->



  <iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>

  <form method="POST" name="form" action="/applydb.cgi?p=tailscale_" target="hidden_frame">
    <input type="hidden" name="current_page" value="Module_tailscale.asp"/>
    <input type="hidden" name="next_page" value="Module_tailscale.asp"/>
    <input type="hidden" name="group_id" value=""/>
    <input type="hidden" name="modified" value="0"/>
    <input type="hidden" name="action_mode" value=""/>
    <input type="hidden" name="action_script" value=""/>
    <input type="hidden" name="action_wait" value="5"/>
    <input type="hidden" name="first_time" value=""/>
    <input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>"/>
    <input type="hidden" name="SystemCmd" value="tailscale_config"/>
    <input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>"/>
    <!-- hidden dbus mirrors for checkboxes -->
    <input type="hidden" id="tailscale_enable" name="tailscale_enable" value='<% dbus_get_def("tailscale_enable","0"); %>'/>
    <input type="hidden" id="tailscale_role" name="tailscale_role" value='<% dbus_get_def("tailscale_role",""); %>'/>
    <input type="hidden" id="tailscale_ipv4_enable" name="tailscale_ipv4_enable" value='<% dbus_get_def("tailscale_ipv4_enable","1"); %>'/>
    <input type="hidden" id="tailscale_ipv6_enable" name="tailscale_ipv6_enable" value='<% dbus_get_def("tailscale_ipv6_enable","1"); %>'/>
    <!-- <input type="hidden" id="tailscale_accept_routes" name="tailscale_accept_routes" value='<% dbus_get_def("tailscale_accept_routes","1"); %>'/> -->
  	<input type="hidden" id="tailscale_SNAT_enable" name="tailscale_SNAT_enable" value='<% dbus_get_def("tailscale_SNAT_enable","1"); %>'/>
    <input type="hidden" id="tailscale_advertise_exit" name="tailscale_advertise_exit" value='<% dbus_get_def("tailscale_advertise_exit","0"); %>'/>
    <input type="hidden" id="tailscale_private_enable" name="tailscale_private_enable" value='<% dbus_get_def("tailscale_private_enable","0"); %>'/>
    <input type="hidden" id="tailscale_login_server"  name="tailscale_login_server"  value='<% dbus_get_def("tailscale_login_server",""); %>'/>

    <table class="content" align="center" cellpadding="0" cellspacing="0">
      <tr>
        <td width="17">&nbsp;</td>
        <td valign="top" width="202">
          <div id="mainMenu"></div>
          <div id="subMenu"></div>
        </td>
        <td valign="top">
          <div id="tabMenu" class="submenuBlock"></div>
          <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
            <tr>
              <td align="left" valign="top">
                <table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
                  <tr>
                    <td bgcolor="#4D595D" colspan="3" valign="top">
                      <div>&nbsp;</div>
                      <div style="float:left;" class="formfonttitle">梅林固件 - Tailscale</div>
                      <div style="float:right; width:15px; height:25px;margin-top:10px">
                        <img id="return_btn" onclick="reload_Soft_Center();" align="right" style="cursor:pointer;position:absolute;margin-left:-30px;margin-top:-25px;" title="返回软件中心" src="/images/backprev.png" onMouseOver="this.src='/images/backprevclick.png'" onMouseOut="this.src='/images/backprev.png'">
                      </div>
                      <div style="margin-left:5px;margin-top:10px;margin-bottom:10px">
                        <img src="/images/New_ui/export/line_export.png">
                      </div>

                      <!-- 开关 -->
                      <table style="margin:10px 0 0 0;" width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
						          <thead>
                          <tr>
                            <td colspan="2">Tailscale 开关</td>
                          </tr>
                        </thead>
                        <tr>
                          <th>启用 Tailscale</th>
                          <td colspan="2">
                            <div class="switch_field" style="display:inline-block; vertical-align:middle;">
                              <label for="switch_enable">
                                <input id="switch_enable" class="switch" type="checkbox" style="display:none;">
                                <div class="switch_container">
                                  <div class="switch_bar"></div>
                                  <div class="switch_circle transition_style"><div></div></div>
                                </div>
                              </label>
                            </div>
                           <!-- 版本号显示（本地 dbus 值：相当于 `dbus get tailscale_version`） -->
                            <span id="ts_version_show" style="display:inline-block; vertical-align:middle; margin-left:2ch;">
                              <a class="hintstyle" href="javascript:void(0);">
                              <i>当前版本：<% dbus_get_def("tailscale_version","未知"); %></i>
                              </a>
                            </span>

                            <!-- 预留“检查并更新”按钮（未来接 GitHub 最新版本比较后启用） -->
                            <!--
                              <div id="ts_update_button" style="display:table-cell;float:left;margin-left:120px;padding: 5.5px 0;">
                                <a id="tsUpdateBtn" type="button" class="ss_btn" style="cursor:not-allowed;opacity:.5"
                                  onclick="ts_check_update()" disabled>检查并更新</a>
                              </div>
                              -->
                            </td>
                          </tr>
                        </table>

                        <!-- 详细设置 -->
                        <table style="margin:10px 0 0 0;" width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">                  
                      <thead>
                          <tr>
                            <td colspan="2">详细设置</td>
                          </tr>
                        </thead>
                        <tr>
                          <th>协议</th>
                          <td>
                            IPv4 <input type="checkbox" id="cb_ipv4" style="vertical-align:middle;" checked/>
                            &nbsp;&nbsp;IPv6 <input type="checkbox" id="cb_ipv6" style="vertical-align:middle;" checked/>
                          </td>
                        </tr>
                        <tr>
                          <th>角色</th>
                          <td>
                          <select id="sel_role" class="input_ss_table" style="width:160px;">
                            <option value="1">网关（子网路由）</option>
                            <option value="2">终端（普通节点）</option>
                            <option value="3">混合（网关+终端）</option>
                          </select>
                          </td>
                        </tr>
                        <tr>
                          <th>Auth Key</th>
                          <td>
                            <input type="password" id="tailscale_authkey" name="tailscale_authkey"  class="input_ss_table" style="width:360px;"
                              placeholder="tskey-..." autocomplete="new-password" autocorrect="off" autocapitalize="off"  maxlength="100" value="" readonly
                              data-b64="<% dbus_get_def("tailscale_authkey",""); %>"
                              onfocus="switchType(this,true); this.removeAttribute('readonly');"
                              onblur="switchType(this,false);" />
                          </td>
                        </tr>
                        <tr>
                          <th>Advertise routes (CIDR)</th>
                          <td>

                          <input type="text" id="tailscale_advertise_routes" name="tailscale_advertise_routes"
                              class="input_ss_table" style="width:280px;"
                              placeholder="例：192.168.1.0/24,10.0.0.0/24"/>

                          <!-- &nbsp;&nbsp;
                          <label><input type="checkbox" id="cb_accept_routes" checked/> 接受其它路由</label> -->

                          &nbsp;&nbsp;
                          <label title="开启：无需回程路由；关闭：需在内网网关配置回程路由">
                            <input type="checkbox" id="cb_snat_enable" checked/> 启用 SNAT（伪装）
                          </label>
                          </td>
                        </tr>
                          <th>出口节点</th>
                          <td>
                            <label><input type="checkbox" id="cb_adv_exit"/> 将本机设为 Exit Node</label>
                          </td>
                        </tr>
                        <tr>
                          <th>私有化部署（Headscale）</th>
                          <td>
                            <label style="margin-right:1em;">
                              <input type="checkbox" id="cb_private_enable"/>
                              启用私有化控制平面
                            </label>
                            <input type="text" id="input_login_server" class="input_ss_table" style="width:320px;"
                                  placeholder="例如：https://headscale.example.com"/>
                            <span class="hintstyle" style="margin-left:.5em;">用于 <code>--login-server</code></span>
                          </td>
                      </tr>
                      </table>

                      <div class="apply_gen" style="margin-top:10px;">
                        <button id="cmdBtn" class="button_gen" onclick="return onSubmitCtrl(event, ' Refresh ');">保存&提交</button>
                        <button class="button_gen" href="javascript:void(0)" onclick="open_status()">查看状态</button>
                        <button class="button_gen" href="javascript:void(0)" onclick="open_netcheck()">网络检测</button>
                        <button class="button_gen" onclick="window.open('https://login.tailscale.com/admin', '_blank')">管理控制台</button>
                      </div>

                      <div style="margin-left:5px;margin-top:10px;margin-bottom:10px">
                        <img src="/images/New_ui/export/line_export.png">
                      </div>

                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>

        </td>
      </tr>
    </table>
  </form>

  <div id="footer"></div>

  <script>
    // 返回软件中心（保持与你现有页面一致）
    function reload_Soft_Center() {
      location.href = "/Main_Soft_center.asp";
    }
  </script>
  <style>
  /* 兜底把遮罩&黑框顶到最上层，防止被旧样式 visibility:hidden / z-index 压住 */
  #Loading { 
    position: fixed !important; left:0; top:0; width:100%; height:100%;
    background: rgba(0,0,0,.6);
    z-index: 99998 !important;
    visibility: visible !important;
  }
  #LoadingBar {
    position: fixed !important; left:0; top:0; width:100%; height:100%;
    z-index: 99999 !important;
    visibility: visible !important;
  }
  /* 居中黑框主体（表格） */
  #loadingBarBlock {
    margin: 0 auto !important;
    /* 用绝对居中，避免“margin-top:60px + 外层布局”导致跑偏 */
    position: absolute; left: 50%; top: 50%;
    transform: translate(-50%, -50%);
    width: 770px;
    background: #000;
    color: #fff;
    border-radius: 6px;
    box-shadow: 0 10px 40px rgba(0,0,0,.6);
  }
  /* 按钮容器置中 */
  #ok_button { text-align: center; padding: 12px 0; background:#000; }
</style>

</body>
</html>
