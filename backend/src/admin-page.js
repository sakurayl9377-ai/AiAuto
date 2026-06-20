export function renderAdminPage() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CodeMate 授权后台</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fa;
      --surface: #ffffff;
      --text: #172033;
      --muted: #667085;
      --line: #d8dee8;
      --accent: #0f766e;
      --accent-strong: #0b5f59;
      --danger: #b42318;
      --warning: #b54708;
      --ok: #087443;
      --shadow: 0 12px 28px rgba(16, 24, 40, 0.08);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: "Microsoft YaHei UI", "Segoe UI", system-ui, sans-serif;
      font-size: 14px;
      letter-spacing: 0;
    }

    header {
      position: sticky;
      top: 0;
      z-index: 10;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 14px 24px;
      background: rgba(255, 255, 255, 0.95);
      border-bottom: 1px solid var(--line);
      backdrop-filter: blur(10px);
    }

    h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 650;
    }

    h2 {
      margin: 0 0 14px;
      font-size: 16px;
      font-weight: 650;
    }

    main {
      width: min(1440px, calc(100vw - 32px));
      margin: 18px auto 34px;
    }

    .auth-shell {
      min-height: calc(100vh - 80px);
      display: grid;
      place-items: center;
      padding: 28px 12px;
    }

    .auth-panel {
      width: min(440px, 100%);
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: 24px;
    }

    .auth-panel h1 {
      margin-bottom: 8px;
    }

    .auth-panel p {
      margin: 0 0 18px;
      color: var(--muted);
      line-height: 1.6;
    }

    .panel,
    .stat {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
    }

    .toolbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 14px;
    }

    .stats {
      display: grid;
      grid-template-columns: repeat(6, minmax(120px, 1fr));
      gap: 12px;
      margin-bottom: 14px;
    }

    .stat {
      padding: 14px;
      box-shadow: none;
    }

    .stat .label {
      color: var(--muted);
      font-size: 12px;
    }

    .stat .value {
      margin-top: 6px;
      font-size: 24px;
      font-weight: 700;
    }

    .grid {
      display: grid;
      grid-template-columns: 360px minmax(0, 1fr);
      gap: 14px;
      align-items: start;
    }

    .panel {
      padding: 16px;
      overflow: hidden;
    }

    .full { grid-column: 1 / -1; }

    .form-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
    }

    .form-grid .wide { grid-column: 1 / -1; }

    label {
      display: grid;
      gap: 6px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 600;
    }

    input,
    select,
    textarea {
      width: 100%;
      min-height: 34px;
      padding: 7px 9px;
      border: 1px solid #c8d0dc;
      border-radius: 6px;
      background: #fff;
      color: var(--text);
      font: inherit;
    }

    textarea {
      min-height: 84px;
      resize: vertical;
      font-family: Consolas, "SFMono-Regular", monospace;
      font-size: 12px;
    }

    button {
      min-height: 34px;
      padding: 7px 12px;
      border: 1px solid transparent;
      border-radius: 6px;
      background: var(--accent);
      color: #fff;
      font: inherit;
      font-weight: 650;
      cursor: pointer;
      white-space: nowrap;
    }

    button:hover { background: var(--accent-strong); }
    button:disabled { opacity: 0.55; cursor: not-allowed; }

    button.secondary {
      background: #fff;
      color: var(--text);
      border-color: #c8d0dc;
    }

    button.secondary:hover { background: #eef2f6; }

    button.danger { background: var(--danger); }
    button.danger:hover { background: #8f1d13; }

    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 14px;
    }

    .filters {
      display: grid;
      grid-template-columns: minmax(180px, 1fr) 150px auto;
      gap: 10px;
      align-items: end;
      margin-bottom: 12px;
    }

    .license-filters {
      grid-template-columns: minmax(180px, 1fr) 150px 150px auto;
    }

    .table-wrap {
      overflow: auto;
      border: 1px solid var(--line);
      border-radius: 8px;
      max-height: 520px;
      background: #fff;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      min-width: 840px;
    }

    th,
    td {
      padding: 10px 11px;
      border-bottom: 1px solid #edf0f5;
      text-align: left;
      vertical-align: top;
    }

    th {
      position: sticky;
      top: 0;
      z-index: 1;
      background: #f8fafc;
      color: #475467;
      font-size: 12px;
      font-weight: 700;
    }

    tr:last-child td { border-bottom: 0; }
    tr:hover td { background: #fbfcfe; }

    .code {
      font-family: Consolas, "SFMono-Regular", monospace;
      font-size: 12px;
    }

    .pill {
      display: inline-flex;
      align-items: center;
      min-height: 22px;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      background: #eef2f6;
      color: #344054;
    }

    .pill.active { background: #e7f6ee; color: var(--ok); }
    .pill.revoked { background: #fdecec; color: var(--danger); }
    .pill.expired { background: #fff4e5; color: var(--warning); }
    .pill.used { background: #e0f2fe; color: #075985; }
    .pill.unbound { background: #eef2f6; color: #475467; }

    .muted { color: var(--muted); }

    .result {
      margin-top: 12px;
      min-height: 92px;
      padding: 10px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #0f172a;
      color: #d1fae5;
      overflow: auto;
      font-family: Consolas, "SFMono-Regular", monospace;
      font-size: 12px;
      white-space: pre-wrap;
    }

    .detail-grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(120px, 1fr));
      gap: 10px;
      margin-bottom: 12px;
    }

    .field {
      padding: 9px 10px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
    }

    .field .name {
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 5px;
    }

    .field .data {
      overflow-wrap: anywhere;
      font-weight: 650;
    }

    .status-line {
      color: var(--muted);
      font-size: 13px;
    }

    .status-line.error { color: var(--danger); font-weight: 650; }
    .status-line.ok { color: var(--ok); font-weight: 650; }

    [hidden] { display: none !important; }

    @media (max-width: 980px) {
      header { align-items: flex-start; flex-direction: column; }
      main { width: min(100vw - 20px, 1440px); }
      .grid,
      .filters,
      .stats,
      .toolbar {
        grid-template-columns: 1fr;
        flex-direction: column;
        align-items: stretch;
      }
      .detail-grid,
      .form-grid {
        grid-template-columns: 1fr;
      }
      .form-grid .wide { grid-column: auto; }
    }
  </style>
</head>
<body>
  <header id="appHeader" hidden>
    <h1>CodeMate 授权后台</h1>
    <div class="toolbar" style="margin:0;">
      <span id="currentUser" class="status-line"></span>
      <button id="refreshAll" class="secondary">刷新</button>
      <button id="logoutButton" class="secondary">退出登录</button>
    </div>
  </header>

  <main id="authShell" class="auth-shell">
    <section id="setupPanel" class="auth-panel" hidden>
      <h1>初始化管理员</h1>
      <p>首次部署需要创建后台管理员账号。账号创建后，后续访问后台都需要登录。</p>
      <form id="setupForm">
        <div class="form-grid" style="grid-template-columns: 1fr;">
          <label>管理员账号
            <input id="setupUsername" autocomplete="username" placeholder="admin">
          </label>
          <label>管理员密码
            <input id="setupPassword" type="password" autocomplete="new-password" placeholder="至少 8 位">
          </label>
          <label>确认密码
            <input id="setupPasswordConfirm" type="password" autocomplete="new-password">
          </label>
        </div>
        <div class="actions">
          <button type="submit">创建管理员</button>
        </div>
      </form>
      <div id="setupStatus" class="status-line" style="margin-top:12px;"></div>
    </section>

    <section id="loginPanel" class="auth-panel" hidden>
      <h1>管理员登录</h1>
      <p>请输入管理员账号和密码进入授权后台。</p>
      <form id="loginForm">
        <div class="form-grid" style="grid-template-columns: 1fr;">
          <label>管理员账号
            <input id="loginUsername" autocomplete="username">
          </label>
          <label>管理员密码
            <input id="loginPassword" type="password" autocomplete="current-password">
          </label>
        </div>
        <div class="actions">
          <button type="submit">登录</button>
        </div>
      </form>
      <div id="loginStatus" class="status-line" style="margin-top:12px;"></div>
    </section>
  </main>

  <main id="dashboard" hidden>
    <section class="stats">
      <div class="stat"><div class="label">授权码总数</div><div id="statTotal" class="value">0</div></div>
      <div class="stat"><div class="label">有效授权</div><div id="statActive" class="value">0</div></div>
      <div class="stat"><div class="label">已吊销</div><div id="statRevoked" class="value">0</div></div>
      <div class="stat"><div class="label">已过期</div><div id="statExpired" class="value">0</div></div>
      <div class="stat"><div class="label">已绑定设备</div><div id="statActivations" class="value">0</div></div>
      <div class="stat"><div class="label">订单记录</div><div id="statOrders" class="value">0</div></div>
    </section>

    <section class="grid">
      <div class="panel">
        <h2>创建授权码</h2>
        <form id="createForm">
          <div class="form-grid">
            <label>套餐
              <input id="createPlan" value="pro">
            </label>
            <label>可绑定设备数
              <input id="createMax" type="number" min="1" max="50" value="1">
            </label>
            <label>生成数量
              <input id="createCount" type="number" min="1" max="500" value="1">
            </label>
            <label>到期时间
              <input id="createExpires" type="datetime-local">
            </label>
            <label>订单号
              <input id="createOrder">
            </label>
            <label>买家标识
              <input id="createBuyer">
            </label>
            <label class="wide">备注 JSON
              <textarea id="createMetadata" spellcheck="false">{}</textarea>
            </label>
          </div>
          <div class="actions">
            <button type="submit">创建</button>
            <button type="button" id="resetCreate" class="secondary">重置</button>
          </div>
        </form>
        <pre id="createResult" class="result">还没有创建授权码。</pre>
      </div>

      <div class="panel">
        <h2>授权码列表</h2>
        <div class="filters license-filters">
          <label>搜索
            <input id="licenseQuery" placeholder="授权码、套餐、订单、买家">
          </label>
          <label>授权状态
            <select id="licenseStatus">
              <option value="">全部</option>
              <option value="active">有效</option>
              <option value="revoked">已吊销</option>
              <option value="expired">已过期</option>
            </select>
          </label>
          <label>使用状态
            <select id="licenseUsage">
              <option value="unused" selected>未使用</option>
              <option value="used">已使用</option>
              <option value="">全部</option>
            </select>
          </label>
          <button id="loadLicenses" class="secondary">筛选</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>授权码</th>
                <th>状态</th>
                <th>套餐</th>
                <th>设备</th>
                <th>到期</th>
                <th>买家</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody id="licensesBody">
              <tr><td colspan="7" class="muted">暂无数据。</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="panel full">
        <h2>授权详情</h2>
        <div id="detailEmpty" class="muted">请选择一条授权码。</div>
        <div id="detailView" hidden>
          <div id="detailFields" class="detail-grid"></div>
          <div class="actions">
            <button id="detailCopy" class="secondary">复制授权码</button>
            <button id="detailReinstate" class="secondary">恢复授权</button>
            <button id="detailRevoke" class="danger">吊销授权</button>
          </div>
          <h2 style="margin-top: 18px;">设备绑定</h2>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>机器码</th>
                  <th>邮箱</th>
                  <th>状态</th>
                  <th>创建时间</th>
                  <th>最后验证</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody id="activationsBody"></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="panel full">
        <h2>订单记录</h2>
        <div class="filters">
          <label>搜索
            <input id="orderQuery" placeholder="订单号、买家、授权码">
          </label>
          <span></span>
          <button id="loadOrders" class="secondary">筛选</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>订单号</th>
                <th>买家</th>
                <th>授权码</th>
                <th>创建时间</th>
              </tr>
            </thead>
            <tbody id="ordersBody">
              <tr><td colspan="4" class="muted">暂无数据。</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
  </main>

  <script>
    const state = {
      selectedCode: null,
      user: null
    };

    const el = (id) => document.getElementById(id);

    function escapeHtml(value) {
      return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
    }

    function shortText(value, size) {
      const text = String(value || "");
      if (!text) return "";
      return text.length > size ? text.slice(0, size) + "..." : text;
    }

    function formatDate(value) {
      if (!value) return "";
      const date = new Date(value);
      if (Number.isNaN(date.getTime())) return value;
      return date.toLocaleString();
    }

    function statusLabel(status, expiresAt) {
      if (expiresAt && new Date(expiresAt).getTime() < Date.now()) return "已过期";
      if (status === "active") return "有效";
      if (status === "revoked") return "已吊销";
      if (status === "unbound") return "已解绑";
      return status || "未知";
    }

    function statusPill(status, expiresAt) {
      const expired = expiresAt && new Date(expiresAt).getTime() < Date.now();
      const cls = expired ? "expired" : String(status || "").toLowerCase();
      return '<span class="pill ' + escapeHtml(cls) + '">' + escapeHtml(statusLabel(status, expiresAt)) + '</span>';
    }

    function showMessage(target, text, kind) {
      target.textContent = text || "";
      target.className = "status-line " + (kind || "");
    }

    async function api(path, options) {
      const config = Object.assign({ method: "GET" }, options || {});
      config.headers = Object.assign({ "Content-Type": "application/json" }, config.headers || {});
      if (config.body && typeof config.body !== "string") {
        config.body = JSON.stringify(config.body);
      }

      const response = await fetch(path, config);
      const text = await response.text();
      let data = {};
      try {
        data = text ? JSON.parse(text) : {};
      } catch {
        data = { ok: false, message: text || "服务器响应格式异常。" };
      }
      if (!response.ok || data.ok === false) {
        throw new Error(data.message || ("HTTP " + response.status));
      }
      return data;
    }

    function showSetup() {
      el("appHeader").hidden = true;
      el("dashboard").hidden = true;
      el("authShell").hidden = false;
      el("setupPanel").hidden = false;
      el("loginPanel").hidden = true;
      el("setupUsername").focus();
    }

    function showLogin() {
      el("appHeader").hidden = true;
      el("dashboard").hidden = true;
      el("authShell").hidden = false;
      el("setupPanel").hidden = true;
      el("loginPanel").hidden = false;
      el("loginUsername").focus();
    }

    function showDashboard(user) {
      state.user = user;
      el("authShell").hidden = true;
      el("setupPanel").hidden = true;
      el("loginPanel").hidden = true;
      el("appHeader").hidden = false;
      el("dashboard").hidden = false;
      el("currentUser").textContent = user?.username ? "当前管理员：" + user.username : "";
      refreshAll();
    }

    async function checkAuthStatus() {
      try {
        const data = await api("/api/admin/auth/status");
        if (!data.initialized) return showSetup();
        if (!data.authenticated) return showLogin();
        showDashboard(data.user);
      } catch {
        showLogin();
      }
    }

    function readCreatePayload() {
      let metadata = {};
      const metadataRaw = el("createMetadata").value.trim();
      if (metadataRaw) {
        metadata = JSON.parse(metadataRaw);
      }
      const expiresRaw = el("createExpires").value;
      return {
        plan: el("createPlan").value.trim() || "pro",
        maxActivations: Number(el("createMax").value || 1),
        expiresAt: expiresRaw ? new Date(expiresRaw).toISOString() : null,
        orderId: el("createOrder").value.trim() || null,
        buyerId: el("createBuyer").value.trim() || null,
        metadata
      };
    }

    async function loadSummary() {
      const data = await api("/api/admin/summary");
      el("statTotal").textContent = data.summary.licenses;
      el("statActive").textContent = data.summary.activeLicenses;
      el("statRevoked").textContent = data.summary.revokedLicenses;
      el("statExpired").textContent = data.summary.expiredLicenses;
      el("statActivations").textContent = data.summary.activeActivations;
      el("statOrders").textContent = data.summary.orders;
    }

    async function loadLicenses() {
      const params = new URLSearchParams();
      const query = el("licenseQuery").value.trim();
      const status = el("licenseStatus").value;
      const usage = el("licenseUsage").value;
      if (query) params.set("q", query);
      if (status) params.set("status", status);
      if (usage) params.set("usage", usage);
      const data = await api("/api/admin/licenses?" + params.toString());
      const rows = data.licenses || [];
      if (!rows.length) {
        el("licensesBody").innerHTML = '<tr><td colspan="7" class="muted">没有找到授权码。</td></tr>';
        return;
      }
      el("licensesBody").innerHTML = rows.map((license) => {
        const usageAction = license.isUsed
          ? '<span class="pill used">已使用</span>'
          : '<button class="secondary" data-action="mark-used" data-code="' + escapeHtml(license.code) + '">使用</button>';
        return '<tr>' +
          '<td class="code">' + escapeHtml(license.code) + '</td>' +
          '<td>' + statusPill(license.status, license.expiresAt) + '</td>' +
          '<td>' + escapeHtml(license.plan) + '</td>' +
          '<td>' + escapeHtml(license.activeActivations) + ' / ' + escapeHtml(license.maxActivations) + '</td>' +
          '<td>' + escapeHtml(formatDate(license.expiresAt) || "永久") + '</td>' +
          '<td>' + escapeHtml(license.buyerId || "") + '</td>' +
          '<td class="actions" style="margin:0;">' +
            '<button class="secondary" data-action="open" data-code="' + escapeHtml(license.code) + '">查看</button>' +
            '<button class="secondary" data-action="copy" data-code="' + escapeHtml(license.code) + '">复制</button>' +
            usageAction +
          '</td>' +
        '</tr>';
      }).join("");
    }

    async function loadOrders() {
      const params = new URLSearchParams();
      const query = el("orderQuery").value.trim();
      if (query) params.set("q", query);
      const data = await api("/api/admin/orders?" + params.toString());
      const rows = data.orders || [];
      if (!rows.length) {
        el("ordersBody").innerHTML = '<tr><td colspan="4" class="muted">暂无订单记录。</td></tr>';
        return;
      }
      el("ordersBody").innerHTML = rows.map((order) => {
        return '<tr>' +
          '<td>' + escapeHtml(order.externalOrderId) + '</td>' +
          '<td>' + escapeHtml(order.buyerId || "") + '</td>' +
          '<td class="code">' + escapeHtml(order.licenseCode || "") + '</td>' +
          '<td>' + escapeHtml(formatDate(order.createdAt)) + '</td>' +
        '</tr>';
      }).join("");
    }

    function renderDetail(data) {
      const license = data.license;
      state.selectedCode = license.code;
      el("detailEmpty").hidden = true;
      el("detailView").hidden = false;
      const fields = [
        ["授权码", license.code],
        ["状态", statusLabel(license.status, license.expiresAt)],
        ["使用状态", license.isUsed ? "已使用" : "未使用"],
        ["套餐", license.plan],
        ["设备", String(license.activeActivations) + " / " + String(license.maxActivations)],
        ["到期", formatDate(license.expiresAt) || "永久"],
        ["手动使用时间", formatDate(license.manualUsedAt) || ""],
        ["订单", license.orderId || ""],
        ["买家", license.buyerId || ""],
        ["创建时间", formatDate(license.createdAt)]
      ];
      el("detailFields").innerHTML = fields.map((field) => {
        return '<div class="field"><div class="name">' + escapeHtml(field[0]) + '</div><div class="data">' + escapeHtml(field[1]) + '</div></div>';
      }).join("");

      const activations = data.activations || [];
      if (!activations.length) {
        el("activationsBody").innerHTML = '<tr><td colspan="7" class="muted">还没有设备绑定。</td></tr>';
        return;
      }
      el("activationsBody").innerHTML = activations.map((activation) => {
        const active = activation.status === "active";
        return '<tr>' +
          '<td>' + escapeHtml(activation.id) + '</td>' +
          '<td class="code" title="' + escapeHtml(activation.machineId) + '">' + escapeHtml(shortText(activation.machineId, 28)) + '</td>' +
          '<td>' + escapeHtml(activation.email || "") + '</td>' +
          '<td>' + statusPill(activation.status, null) + '</td>' +
          '<td>' + escapeHtml(formatDate(activation.createdAt)) + '</td>' +
          '<td>' + escapeHtml(formatDate(activation.lastSeenAt)) + '</td>' +
          '<td class="actions" style="margin:0;">' +
            (active ? '<button class="danger" data-action="unbind" data-id="' + escapeHtml(activation.id) + '">解绑</button>' : '<span class="muted">不可操作</span>') +
          '</td>' +
        '</tr>';
      }).join("");
    }

    async function openLicense(code) {
      const data = await api("/api/admin/licenses/" + encodeURIComponent(code));
      renderDetail(data);
    }

    async function revokeLicense(code) {
      const reason = prompt("请输入吊销原因", "管理员吊销");
      if (reason === null) return;
      await api("/api/licenses/revoke", {
        method: "POST",
        body: { code, reason }
      });
      await refreshAll();
      await openLicense(code);
    }

    async function reinstateLicense(code) {
      await api("/api/admin/licenses/" + encodeURIComponent(code) + "/reinstate", { method: "POST" });
      await refreshAll();
      await openLicense(code);
    }

    async function markLicenseUsed(code) {
      if (!confirm("确定将该授权码标记为已使用吗？")) return;
      await api("/api/admin/licenses/" + encodeURIComponent(code) + "/mark-used", { method: "POST" });
      await refreshAll();
      if (state.selectedCode === code) await openLicense(code);
    }

    async function unbindActivation(code, activationId) {
      if (!confirm("确定解绑该设备吗？解绑后此设备需要重新激活。")) return;
      await api("/api/admin/licenses/" + encodeURIComponent(code) + "/activations/" + encodeURIComponent(activationId) + "/unbind", { method: "POST" });
      await refreshAll();
      await openLicense(code);
    }

    async function copyText(text) {
      await navigator.clipboard.writeText(text);
      el("currentUser").textContent = "已复制授权码：" + text;
    }

    async function refreshAll() {
      try {
        await loadSummary();
        await loadLicenses();
        await loadOrders();
        if (state.user?.username) {
          el("currentUser").textContent = "当前管理员：" + state.user.username + "，已刷新 " + new Date().toLocaleTimeString();
        }
      } catch (error) {
        if (String(error.message).includes("登录")) {
          showLogin();
        } else {
          el("currentUser").textContent = error.message;
        }
      }
    }

    el("setupForm").addEventListener("submit", async (event) => {
      event.preventDefault();
      const username = el("setupUsername").value.trim();
      const password = el("setupPassword").value;
      const confirmPassword = el("setupPasswordConfirm").value;
      if (password !== confirmPassword) {
        showMessage(el("setupStatus"), "两次输入的密码不一致。", "error");
        return;
      }

      try {
        await api("/api/admin/auth/setup", {
          method: "POST",
          body: { username, password }
        });
        showMessage(el("setupStatus"), "管理员已创建，请登录。", "ok");
        el("loginUsername").value = username;
        showLogin();
      } catch (error) {
        showMessage(el("setupStatus"), error.message, "error");
      }
    });

    el("loginForm").addEventListener("submit", async (event) => {
      event.preventDefault();
      try {
        const data = await api("/api/admin/auth/login", {
          method: "POST",
          body: {
            username: el("loginUsername").value.trim(),
            password: el("loginPassword").value
          }
        });
        el("loginPassword").value = "";
        showDashboard(data.user);
      } catch (error) {
        showMessage(el("loginStatus"), error.message, "error");
      }
    });

    el("logoutButton").addEventListener("click", async () => {
      try {
        await api("/api/admin/auth/logout", { method: "POST" });
      } catch {}
      state.user = null;
      showLogin();
    });

    el("refreshAll").addEventListener("click", refreshAll);
    el("loadLicenses").addEventListener("click", () => loadLicenses().catch((error) => { el("currentUser").textContent = error.message; }));
    el("loadOrders").addEventListener("click", () => loadOrders().catch((error) => { el("currentUser").textContent = error.message; }));
    el("resetCreate").addEventListener("click", () => {
      el("createForm").reset();
      el("createMetadata").value = "{}";
      el("createResult").textContent = "还没有创建授权码。";
    });

    el("createForm").addEventListener("submit", async (event) => {
      event.preventDefault();
      try {
        const body = readCreatePayload();
        const count = Math.max(1, Math.min(500, Number(el("createCount").value || 1)));
        const path = count > 1 ? "/api/licenses/bulk-create" : "/api/licenses/create";
        if (count > 1) body.count = count;
        const data = await api(path, { method: "POST", body });
        el("createResult").textContent = JSON.stringify(data, null, 2);
        await refreshAll();
      } catch (error) {
        el("createResult").textContent = error.message;
      }
    });

    el("licensesBody").addEventListener("click", async (event) => {
      const button = event.target.closest("button");
      if (!button) return;
      const code = button.getAttribute("data-code");
      const action = button.getAttribute("data-action");
      try {
        if (action === "open") await openLicense(code);
        if (action === "copy") await copyText(code);
        if (action === "mark-used") await markLicenseUsed(code);
      } catch (error) {
        el("currentUser").textContent = error.message;
      }
    });

    el("activationsBody").addEventListener("click", async (event) => {
      const button = event.target.closest("button");
      if (!button || button.getAttribute("data-action") !== "unbind") return;
      try {
        await unbindActivation(state.selectedCode, button.getAttribute("data-id"));
      } catch (error) {
        el("currentUser").textContent = error.message;
      }
    });

    el("detailCopy").addEventListener("click", () => {
      if (state.selectedCode) copyText(state.selectedCode);
    });
    el("detailRevoke").addEventListener("click", () => {
      if (state.selectedCode) revokeLicense(state.selectedCode).catch((error) => { el("currentUser").textContent = error.message; });
    });
    el("detailReinstate").addEventListener("click", () => {
      if (state.selectedCode) reinstateLicense(state.selectedCode).catch((error) => { el("currentUser").textContent = error.message; });
    });

    checkAuthStatus();
  </script>
</body>
</html>`;
}
