import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import Database from "better-sqlite3";
import cors from "cors";
import dotenv from "dotenv";
import express from "express";
import { renderAdminPage } from "./admin-page.js";

dotenv.config();

const app = express();
app.set("trust proxy", 1);
const port = Number(process.env.PORT || 8787);
const adminToken = process.env.ADMIN_TOKEN || "change-me-admin-token";
const adminSessionDays = Math.max(1, Math.min(30, Number(process.env.ADMIN_SESSION_DAYS || 7)));
const dbPath = process.env.DB_PATH || "./data/licenses.db";

fs.mkdirSync(path.dirname(dbPath), { recursive: true });

const db = new Database(dbPath);
db.pragma("journal_mode = WAL");
db.exec(`
  CREATE TABLE IF NOT EXISTS licenses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    code TEXT NOT NULL UNIQUE,
    plan TEXT NOT NULL,
    status TEXT NOT NULL,
    max_activations INTEGER NOT NULL DEFAULT 1,
    activated_count INTEGER NOT NULL DEFAULT 0,
    expires_at TEXT,
    order_id TEXT,
    buyer_id TEXT,
    metadata_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revoked_reason TEXT
  );

  CREATE TABLE IF NOT EXISTS activations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    license_id INTEGER NOT NULL,
    machine_id TEXT NOT NULL,
    email TEXT,
    token_hash TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    UNIQUE(license_id, machine_id),
    FOREIGN KEY (license_id) REFERENCES licenses(id)
  );

  CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_order_id TEXT NOT NULL UNIQUE,
    buyer_id TEXT,
    payload_json TEXT NOT NULL,
    license_code TEXT,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS admin_users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    password_salt TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_login_at TEXT
  );

  CREATE TABLE IF NOT EXISTS admin_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES admin_users(id)
  );
`);

const licenseColumns = db.prepare("PRAGMA table_info(licenses)").all().map((column) => column.name);
if (!licenseColumns.includes("manual_used_at")) {
  db.prepare("ALTER TABLE licenses ADD COLUMN manual_used_at TEXT").run();
}

app.use(cors());
app.use(express.json({ limit: "1mb" }));

function nowIso() {
  return new Date().toISOString();
}

function addDays(date, days) {
  const copy = new Date(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function parseCookies(req) {
  const header = req.get("cookie") || "";
  const cookies = {};
  for (const part of header.split(";")) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    const key = part.slice(0, index).trim();
    const value = part.slice(index + 1).trim();
    if (key) cookies[key] = decodeURIComponent(value);
  }
  return cookies;
}

function isSecureRequest(req) {
  return req.secure || req.get("x-forwarded-proto") === "https";
}

function setSessionCookie(req, res, token, expiresAt) {
  const parts = [
    `codemate_admin_session=${encodeURIComponent(token)}`,
    "HttpOnly",
    "Path=/",
    "SameSite=Lax",
    `Expires=${expiresAt.toUTCString()}`
  ];

  if (isSecureRequest(req)) {
    parts.push("Secure");
  }

  res.setHeader("Set-Cookie", parts.join("; "));
}

function clearSessionCookie(res) {
  res.setHeader("Set-Cookie", "codemate_admin_session=; HttpOnly; Path=/; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT");
}

function hashPassword(password, salt = crypto.randomBytes(16).toString("hex")) {
  const hash = crypto.scryptSync(String(password), salt, 64).toString("hex");
  return { hash, salt };
}

function verifyPassword(password, row) {
  if (!row) return false;
  const { hash } = hashPassword(password, row.password_salt);
  return crypto.timingSafeEqual(Buffer.from(hash, "hex"), Buffer.from(row.password_hash, "hex"));
}

function adminUserCount() {
  return db.prepare("SELECT COUNT(*) AS count FROM admin_users").get().count;
}

function getAdminSession(req) {
  const token = parseCookies(req).codemate_admin_session;
  if (!token) return null;

  const tokenHash = hashToken(token);
  const row = db.prepare(`
    SELECT s.*, u.username
    FROM admin_sessions s
    JOIN admin_users u ON u.id = s.user_id
    WHERE s.token_hash = ?
  `).get(tokenHash);
  if (!row) return null;

  if (new Date(row.expires_at).getTime() <= Date.now()) {
    db.prepare("DELETE FROM admin_sessions WHERE id = ?").run(row.id);
    return null;
  }

  db.prepare("UPDATE admin_sessions SET last_seen_at = ? WHERE id = ?").run(nowIso(), row.id);
  return {
    id: row.id,
    userId: row.user_id,
    username: row.username,
    expiresAt: row.expires_at
  };
}

function requireAdmin(req, res, next) {
  const header = req.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (token && token === adminToken) {
    req.admin = { mode: "token" };
    return next();
  }

  const session = getAdminSession(req);
  if (session) {
    req.admin = { mode: "session", ...session };
    return next();
  }

  return res.status(401).json({ ok: false, message: "未登录或登录已过期。" });
}

function randomCode() {
  const raw = crypto.randomBytes(12).toString("hex").toUpperCase();
  return `CM-${raw.slice(0, 6)}-${raw.slice(6, 12)}-${raw.slice(12, 18)}-${raw.slice(18, 24)}`;
}

function hashToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function createLicense({
  plan = "pro",
  maxActivations = 1,
  expiresAt = null,
  orderId = null,
  buyerId = null,
  metadata = {}
}) {
  const createdAt = nowIso();
  let code = randomCode();

  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      db.prepare(`
        INSERT INTO licenses (
          code, plan, status, max_activations, expires_at, order_id,
          buyer_id, metadata_json, created_at, updated_at
        )
        VALUES (?, ?, 'active', ?, ?, ?, ?, ?, ?, ?)
      `).run(
        code,
        plan,
        Number(maxActivations || 1),
        expiresAt,
        orderId,
        buyerId,
        JSON.stringify(metadata || {}),
        createdAt,
        createdAt
      );
      return db.prepare("SELECT * FROM licenses WHERE code = ?").get(code);
    } catch (error) {
      if (!String(error.message).includes("UNIQUE")) throw error;
      code = randomCode();
    }
  }

  throw new Error("Failed to create unique license code.");
}

function parseMetadata(row) {
  if (!row?.metadata_json) return {};

  try {
    return JSON.parse(row.metadata_json);
  } catch {
    return {};
  }
}

function publicLicense(row) {
  if (!row) return null;
  return {
    code: row.code,
    plan: row.plan,
    status: row.status,
    maxActivations: row.max_activations,
    activatedCount: row.activated_count,
    expiresAt: row.expires_at,
    orderId: row.order_id,
    buyerId: row.buyer_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    manualUsedAt: row.manual_used_at,
    revokedReason: row.revoked_reason,
    metadata: parseMetadata(row)
  };
}

function isExpired(row) {
  return row.expires_at && new Date(row.expires_at).getTime() < Date.now();
}

function countActiveActivations(licenseId) {
  return db.prepare(`
    SELECT COUNT(*) AS count
    FROM activations
    WHERE license_id = ? AND status = 'active'
  `).get(licenseId).count;
}

function syncActivatedCount(licenseId) {
  const count = countActiveActivations(licenseId);
  db.prepare("UPDATE licenses SET activated_count = ?, updated_at = ? WHERE id = ?").run(count, nowIso(), licenseId);
  return count;
}

function adminLicense(row) {
  if (!row) return null;
  const activeActivations = Number(row.active_activations ?? row.activated_count ?? 0);

  return {
    ...publicLicense(row),
    id: row.id,
    activeActivations,
    totalActivations: Number(row.total_activations ?? 0),
    isUsed: activeActivations > 0 || Boolean(row.manual_used_at),
    isExpired: Boolean(isExpired(row))
  };
}

function publicActivation(row) {
  if (!row) return null;

  return {
    id: row.id,
    licenseId: row.license_id,
    machineId: row.machine_id,
    email: row.email,
    status: row.status,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at
  };
}

function publicOrder(row) {
  if (!row) return null;

  return {
    id: row.id,
    externalOrderId: row.external_order_id,
    buyerId: row.buyer_id,
    licenseCode: row.license_code,
    createdAt: row.created_at
  };
}

app.get("/health", (_req, res) => {
  res.json({ ok: true, product: "codemate-license-server", version: "0.1.0" });
});

app.get("/", (_req, res) => {
  res.redirect("/admin");
});

app.get("/admin", (_req, res) => {
  res.type("html").send(renderAdminPage());
});

app.get("/api/admin/auth/status", (req, res) => {
  const session = getAdminSession(req);
  res.json({
    ok: true,
    initialized: adminUserCount() > 0,
    authenticated: Boolean(session),
    user: session ? { username: session.username, expiresAt: session.expiresAt } : null
  });
});

app.post("/api/admin/auth/setup", (req, res) => {
  if (adminUserCount() > 0) {
    return res.status(409).json({ ok: false, message: "管理员账号已初始化。" });
  }

  const username = String(req.body?.username || "").trim();
  const password = String(req.body?.password || "");
  if (!/^[A-Za-z0-9_.-]{3,32}$/.test(username)) {
    return res.status(400).json({ ok: false, message: "管理员账号需为 3-32 位字母、数字或 ._-。" });
  }
  if (password.length < 8) {
    return res.status(400).json({ ok: false, message: "管理员密码至少需要 8 位。" });
  }

  const { hash, salt } = hashPassword(password);
  const currentTime = nowIso();
  db.prepare(`
    INSERT INTO admin_users (username, password_hash, password_salt, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(username, hash, salt, currentTime, currentTime);

  res.json({ ok: true, message: "管理员账号已创建。" });
});

app.post("/api/admin/auth/login", (req, res) => {
  const username = String(req.body?.username || "").trim();
  const password = String(req.body?.password || "");
  const row = db.prepare("SELECT * FROM admin_users WHERE username = ?").get(username);
  if (!row || !verifyPassword(password, row)) {
    return res.status(401).json({ ok: false, message: "账号或密码错误。" });
  }

  const token = crypto.randomBytes(32).toString("base64url");
  const tokenHash = hashToken(token);
  const currentTime = nowIso();
  const expiresAt = addDays(new Date(), adminSessionDays);
  db.prepare(`
    INSERT INTO admin_sessions (user_id, token_hash, created_at, expires_at, last_seen_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(row.id, tokenHash, currentTime, expiresAt.toISOString(), currentTime);
  db.prepare("UPDATE admin_users SET last_login_at = ?, updated_at = ? WHERE id = ?").run(currentTime, currentTime, row.id);

  setSessionCookie(req, res, token, expiresAt);
  res.json({ ok: true, message: "登录成功。", user: { username: row.username } });
});

app.post("/api/admin/auth/logout", requireAdmin, (req, res) => {
  const token = parseCookies(req).codemate_admin_session;
  if (token) {
    db.prepare("DELETE FROM admin_sessions WHERE token_hash = ?").run(hashToken(token));
  }

  clearSessionCookie(res);
  res.json({ ok: true, message: "已退出登录。" });
});

app.post("/api/licenses/create", requireAdmin, (req, res) => {
  const license = createLicense(req.body || {});
  res.json({ ok: true, license: publicLicense(license) });
});

app.post("/api/licenses/bulk-create", requireAdmin, (req, res) => {
  const count = Math.max(1, Math.min(500, Number(req.body?.count || 1)));
  const created = [];
  const tx = db.transaction(() => {
    for (let index = 0; index < count; index += 1) {
      created.push(publicLicense(createLicense(req.body || {})));
    }
  });
  tx();
  res.json({ ok: true, licenses: created });
});

app.get("/api/licenses/:code", requireAdmin, (req, res) => {
  const row = db.prepare("SELECT * FROM licenses WHERE code = ?").get(req.params.code);
  if (!row) return res.status(404).json({ ok: false, message: "License not found." });
  res.json({ ok: true, license: publicLicense(row) });
});

app.post("/api/licenses/activate", (req, res) => {
  const { code, machineId, email } = req.body || {};
  if (!code || !machineId) {
    return res.status(400).json({ ok: false, message: "code and machineId are required." });
  }

  const row = db.prepare("SELECT * FROM licenses WHERE code = ?").get(String(code).trim());
  if (!row) return res.status(404).json({ ok: false, message: "License code not found." });
  if (row.status !== "active") return res.status(403).json({ ok: false, message: "License is not active." });
  if (isExpired(row)) return res.status(403).json({ ok: false, message: "License expired." });

  const existing = db.prepare("SELECT * FROM activations WHERE license_id = ? AND machine_id = ?").get(row.id, machineId);
  const activeActivationCount = countActiveActivations(row.id);
  const token = crypto.randomBytes(32).toString("base64url");
  const tokenHash = hashToken(token);
  const currentTime = nowIso();

  if (existing) {
    if (existing.status !== "active" && activeActivationCount >= row.max_activations) {
      return res.status(403).json({ ok: false, message: "Activation limit reached." });
    }

    db.prepare(`
      UPDATE activations
      SET token_hash = ?, email = ?, status = 'active', last_seen_at = ?
      WHERE id = ?
    `).run(tokenHash, email || existing.email, currentTime, existing.id);
  } else {
    if (activeActivationCount >= row.max_activations) {
      return res.status(403).json({ ok: false, message: "Activation limit reached." });
    }

    db.prepare(`
      INSERT INTO activations (license_id, machine_id, email, token_hash, status, created_at, last_seen_at)
      VALUES (?, ?, ?, ?, 'active', ?, ?)
    `).run(row.id, machineId, email || null, tokenHash, currentTime, currentTime);

    db.prepare("UPDATE licenses SET updated_at = ? WHERE id = ?").run(currentTime, row.id);
  }

  syncActivatedCount(row.id);

  res.json({
    ok: true,
    message: "License activated.",
    token,
    plan: row.plan,
    status: row.status,
    expiresAt: row.expires_at
  });
});

app.post("/api/licenses/refresh", (req, res) => {
  const { code, token, machineId } = req.body || {};
  if (!code || !token || !machineId) {
    return res.status(400).json({ ok: false, message: "code, token and machineId are required." });
  }

  const row = db.prepare("SELECT * FROM licenses WHERE code = ?").get(String(code).trim());
  if (!row) return res.status(404).json({ ok: false, message: "License code not found." });
  if (row.status !== "active") return res.status(403).json({ ok: false, message: "License is not active." });
  if (isExpired(row)) return res.status(403).json({ ok: false, message: "License expired." });

  const activation = db.prepare("SELECT * FROM activations WHERE license_id = ? AND machine_id = ?").get(row.id, machineId);
  if (!activation || activation.status !== "active") {
    return res.status(403).json({ ok: false, message: "Activation not found." });
  }

  if (activation.token_hash !== hashToken(token)) {
    return res.status(403).json({ ok: false, message: "Invalid activation token." });
  }

  db.prepare("UPDATE activations SET last_seen_at = ? WHERE id = ?").run(nowIso(), activation.id);
  res.json({
    ok: true,
    message: "License is valid.",
    plan: row.plan,
    status: row.status,
    expiresAt: row.expires_at
  });
});

app.post("/api/licenses/revoke", requireAdmin, (req, res) => {
  const { code, reason } = req.body || {};
  if (!code) return res.status(400).json({ ok: false, message: "code is required." });

  const result = db.prepare(`
    UPDATE licenses
    SET status = 'revoked', revoked_reason = ?, updated_at = ?
    WHERE code = ?
  `).run(reason || "revoked", nowIso(), code);

  if (!result.changes) return res.status(404).json({ ok: false, message: "License not found." });
  res.json({ ok: true, message: "License revoked." });
});

app.get("/api/admin/summary", requireAdmin, (_req, res) => {
  const currentTime = nowIso();
  const totalLicenses = db.prepare("SELECT COUNT(*) AS count FROM licenses").get().count;
  const activeLicenses = db.prepare(`
    SELECT COUNT(*) AS count
    FROM licenses
    WHERE status = 'active' AND (expires_at IS NULL OR expires_at >= ?)
  `).get(currentTime).count;
  const revokedLicenses = db.prepare("SELECT COUNT(*) AS count FROM licenses WHERE status = 'revoked'").get().count;
  const expiredLicenses = db.prepare(`
    SELECT COUNT(*) AS count
    FROM licenses
    WHERE expires_at IS NOT NULL AND expires_at < ?
  `).get(currentTime).count;
  const activeActivations = db.prepare("SELECT COUNT(*) AS count FROM activations WHERE status = 'active'").get().count;
  const orders = db.prepare("SELECT COUNT(*) AS count FROM orders").get().count;

  res.json({
    ok: true,
    summary: {
      licenses: totalLicenses,
      activeLicenses,
      revokedLicenses,
      expiredLicenses,
      activeActivations,
      orders
    }
  });
});

app.get("/api/admin/licenses", requireAdmin, (req, res) => {
  const q = String(req.query.q || "").trim();
  const status = String(req.query.status || "").trim();
  const usage = String(req.query.usage || "").trim();
  const limit = Math.max(1, Math.min(500, Number(req.query.limit || 200)));
  const params = [];
  const where = [];
  const having = [];
  const currentTime = nowIso();

  if (q) {
    where.push("(l.code LIKE ? OR l.plan LIKE ? OR l.order_id LIKE ? OR l.buyer_id LIKE ?)");
    const like = `%${q}%`;
    params.push(like, like, like, like);
  }

  if (status === "expired") {
    where.push("l.expires_at IS NOT NULL AND l.expires_at < ?");
    params.push(currentTime);
  } else if (status === "active") {
    where.push("l.status = 'active' AND (l.expires_at IS NULL OR l.expires_at >= ?)");
    params.push(currentTime);
  } else if (status) {
    where.push("l.status = ?");
    params.push(status);
  }

  if (usage === "unused") {
    having.push("active_activations = 0 AND l.manual_used_at IS NULL");
  } else if (usage === "used") {
    having.push("(active_activations > 0 OR l.manual_used_at IS NOT NULL)");
  }

  const licenses = db.prepare(`
    SELECT
      l.*,
      COALESCE(SUM(CASE WHEN a.status = 'active' THEN 1 ELSE 0 END), 0) AS active_activations,
      COUNT(a.id) AS total_activations
    FROM licenses l
    LEFT JOIN activations a ON a.license_id = l.id
    ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
    GROUP BY l.id
    ${having.length ? `HAVING ${having.join(" AND ")}` : ""}
    ORDER BY l.created_at DESC
    LIMIT ?
  `).all(...params, limit).map(adminLicense);

  res.json({ ok: true, licenses });
});

app.get("/api/admin/licenses/:code", requireAdmin, (req, res) => {
  const row = db.prepare(`
    SELECT
      l.*,
      COALESCE(SUM(CASE WHEN a.status = 'active' THEN 1 ELSE 0 END), 0) AS active_activations,
      COUNT(a.id) AS total_activations
    FROM licenses l
    LEFT JOIN activations a ON a.license_id = l.id
    WHERE l.code = ?
    GROUP BY l.id
  `).get(req.params.code);
  if (!row) return res.status(404).json({ ok: false, message: "License not found." });

  const activations = db.prepare(`
    SELECT *
    FROM activations
    WHERE license_id = ?
    ORDER BY last_seen_at DESC
  `).all(row.id).map(publicActivation);

  res.json({ ok: true, license: adminLicense(row), activations });
});

app.post("/api/admin/licenses/:code/reinstate", requireAdmin, (req, res) => {
  const result = db.prepare(`
    UPDATE licenses
    SET status = 'active', revoked_reason = NULL, updated_at = ?
    WHERE code = ?
  `).run(nowIso(), req.params.code);
  if (!result.changes) return res.status(404).json({ ok: false, message: "License not found." });

  const row = db.prepare("SELECT * FROM licenses WHERE code = ?").get(req.params.code);
  res.json({ ok: true, message: "License reinstated.", license: publicLicense(row) });
});

app.post("/api/admin/licenses/:code/mark-used", requireAdmin, (req, res) => {
  const currentTime = nowIso();
  const result = db.prepare(`
    UPDATE licenses
    SET manual_used_at = COALESCE(manual_used_at, ?), updated_at = ?
    WHERE code = ?
  `).run(currentTime, currentTime, req.params.code);
  if (!result.changes) return res.status(404).json({ ok: false, message: "License not found." });

  const row = db.prepare("SELECT * FROM licenses WHERE code = ?").get(req.params.code);
  res.json({ ok: true, message: "License marked as used.", license: publicLicense(row) });
});

app.post("/api/admin/licenses/:code/activations/:activationId/unbind", requireAdmin, (req, res) => {
  const row = db.prepare("SELECT * FROM licenses WHERE code = ?").get(req.params.code);
  if (!row) return res.status(404).json({ ok: false, message: "License not found." });

  const result = db.prepare(`
    UPDATE activations
    SET status = 'unbound', last_seen_at = ?
    WHERE id = ? AND license_id = ?
  `).run(nowIso(), req.params.activationId, row.id);
  if (!result.changes) return res.status(404).json({ ok: false, message: "Activation not found." });

  const activeCount = syncActivatedCount(row.id);
  res.json({ ok: true, message: "Machine unbound.", activeActivations: activeCount });
});

app.get("/api/admin/orders", requireAdmin, (req, res) => {
  const q = String(req.query.q || "").trim();
  const limit = Math.max(1, Math.min(500, Number(req.query.limit || 200)));
  const params = [];
  const where = [];

  if (q) {
    where.push("(external_order_id LIKE ? OR buyer_id LIKE ? OR license_code LIKE ?)");
    const like = `%${q}%`;
    params.push(like, like, like);
  }

  const orders = db.prepare(`
    SELECT *
    FROM orders
    ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
    ORDER BY created_at DESC
    LIMIT ?
  `).all(...params, limit).map(publicOrder);

  res.json({ ok: true, orders });
});

app.post("/api/orders/webhook", (req, res) => {
  const payload = req.body || {};
  const externalOrderId = String(payload.orderId || payload.order_id || "");
  if (!externalOrderId) {
    return res.status(400).json({ ok: false, message: "orderId is required." });
  }

  const existing = db.prepare("SELECT * FROM orders WHERE external_order_id = ?").get(externalOrderId);
  if (existing) {
    return res.json({ ok: true, licenseCode: existing.license_code, idempotent: true });
  }

  const license = createLicense({
    plan: payload.plan || "pro",
    maxActivations: payload.maxActivations || 1,
    expiresAt: payload.expiresAt || null,
    orderId: externalOrderId,
    buyerId: payload.buyerId || payload.buyer_id || null,
    metadata: payload
  });

  db.prepare(`
    INSERT INTO orders (external_order_id, buyer_id, payload_json, license_code, created_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(externalOrderId, payload.buyerId || payload.buyer_id || null, JSON.stringify(payload), license.code, nowIso());

  res.json({
    ok: true,
    licenseCode: license.code,
    message: `感谢购买 CodeMate Setup，授权码：${license.code}`
  });
});

app.use((error, _req, res, _next) => {
  console.error(error);
  res.status(500).json({ ok: false, message: "Internal server error." });
});

app.listen(port, () => {
  console.log(`CodeMate license server listening on http://127.0.0.1:${port}`);
});
