# Berth 官网 + 许可后端

落地页 + 轻后端:候补邮箱、下载计数、许可校验接口(支付接入前为占位)。

## 运行

```bash
npm install
npm start          # http://localhost:8787
npm run dev        # --watch 热重载
```

要求 Node ≥ 22.5(用了内置 `node:sqlite`,无原生依赖)。数据库落在 `data/berth.db`(gitignored)。

## 环境变量

| 变量 | 作用 |
|---|---|
| `PORT` | 监听端口,默认 8787 |
| `DOWNLOAD_URL` | DMG 分发地址;未配置时下载按钮走候补模式 |
| `APP_VERSION` | 展示在下载按钮下方,如 `1.0.0` |
| `ADMIN_TOKEN` | 配置后开启 `GET /api/admin/stats`(Bearer 鉴权) |
| `BERTH_DB` | SQLite 路径覆盖,默认 `./data/berth.db` |

## API

- `GET /api/health` — 探活
- `GET /api/release` — 发布状态(前端下载按钮据此切换)
- `GET /download` — 计数后 302 到 `DOWNLOAD_URL`
- `POST /api/waitlist` — `{email}` 候补;按 IP 限频
- `GET /api/license/verify?key=BERTH-XXXX-XXXX-XXXX` — app 激活校验(结构已定,支付前恒 404)
- `POST /api/checkout` / `POST /api/webhooks/payment` — 支付占位,接入 Stripe/Paddle 时替换
- `GET /api/admin/stats` — 运营数据(需 `ADMIN_TOKEN`)

## 接支付时

1. `POST /api/checkout` 创建支付会话(Stripe Checkout Session / Paddle);
2. webhook 验签后写 `orders`,调用 `generateLicenseKey()` 签发 `licenses`,邮件送达;
3. app 端激活走 `/api/license/verify`。
表结构已在 `db.js` 建好(orders 以 `provider_ref` 幂等)。

## Docker

```bash
docker build -t berth-site .
docker run -d -p 8787:8787 -v berth-site-data:/app/data \
  -e DOWNLOAD_URL=... -e ADMIN_TOKEN=... berth-site
```
