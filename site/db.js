import { DatabaseSync } from 'node:sqlite'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { randomBytes } from 'node:crypto'

const DB_PATH = process.env.BERTH_DB || new URL('./data/berth.db', import.meta.url).pathname

mkdirSync(dirname(DB_PATH), { recursive: true })

export const db = new DatabaseSync(DB_PATH)

db.exec(`
  PRAGMA journal_mode = WAL;

  CREATE TABLE IF NOT EXISTS waitlist (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    email      TEXT NOT NULL UNIQUE COLLATE NOCASE,
    source     TEXT NOT NULL DEFAULT 'landing',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT NOT NULL,              -- download / page_view / checkout_intent …
    meta       TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- 支付接入前先把结构定好:orders 由支付 webhook 写入,licenses 随订单签发
  CREATE TABLE IF NOT EXISTS orders (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    provider     TEXT NOT NULL,            -- stripe / paddle / lemonsqueezy
    provider_ref TEXT NOT NULL UNIQUE,     -- 对方系统的订单/会话 ID,幂等去重
    email        TEXT NOT NULL,
    amount_cents INTEGER NOT NULL,
    currency     TEXT NOT NULL DEFAULT 'CNY',
    status       TEXT NOT NULL DEFAULT 'pending',  -- pending / paid / refunded
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS licenses (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    key          TEXT NOT NULL UNIQUE,
    order_id     INTEGER REFERENCES orders(id),
    email        TEXT NOT NULL,
    seats        INTEGER NOT NULL DEFAULT 1,
    status       TEXT NOT NULL DEFAULT 'active',   -- active / revoked
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    activated_at TEXT
  );
`)

const insertWaitlist = db.prepare(
  'INSERT INTO waitlist (email, source) VALUES (?, ?) ON CONFLICT(email) DO NOTHING'
)
const insertEvent = db.prepare('INSERT INTO events (kind, meta) VALUES (?, ?)')
const findLicense = db.prepare('SELECT key, email, seats, status, created_at FROM licenses WHERE key = ?')

export function addToWaitlist(email, source = 'landing') {
  const result = insertWaitlist.run(email, source)
  return result.changes > 0 // false = 已存在
}

export function recordEvent(kind, meta = null) {
  insertEvent.run(kind, meta ? JSON.stringify(meta) : null)
}

export function lookupLicense(key) {
  return findLicense.get(key) ?? null
}

export function stats() {
  const one = (sql) => Object.values(db.prepare(sql).get())[0]
  return {
    waitlist: one('SELECT COUNT(*) FROM waitlist'),
    downloads: one("SELECT COUNT(*) FROM events WHERE kind = 'download'"),
    orders_paid: one("SELECT COUNT(*) FROM orders WHERE status = 'paid'"),
    licenses_active: one("SELECT COUNT(*) FROM licenses WHERE status = 'active'"),
  }
}

/// 许可 key 生成:BERTH-XXXX-XXXX-XXXX(去掉易混淆字符)。支付接入后由订单流程调用。
const KEY_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
export function generateLicenseKey() {
  const group = () =>
    Array.from(randomBytes(4), (b) => KEY_ALPHABET[b % KEY_ALPHABET.length]).join('')
  return `BERTH-${group()}-${group()}-${group()}`
}
