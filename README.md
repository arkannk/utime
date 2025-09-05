# GMOD-UTime

A lightweight **Garry’s Mod UTime script** that stores **total playtime** and (optionally) **per-job playtime** in MySQL/MariaDB – perfect for **websites or dashboards**.  
The schema is minimal (`steamid64` + `total_seconds` and a per-job table) and is easy to query from Node.js, PHP, Python, etc.

---

## Features

- 🧩 Minimal DB schema for dashboards
- ⚡️ Fast and index-friendly
- 🔌 API-ready: drop-in for Node.js/Express, Next.js, PHP, Python
- 🧱 Optional **per-job time** (`utime_jobtime`) with FK → `utime_players`
- 🔒 Security: split WRITE (game server) vs READ (web) credentials

---

## Database Schema

> **Why `VARCHAR(20)` for `steamid64`?** SteamID64 is up to 17 digits; storing as string avoids precision loss in JS stacks.

### Players (total time)

```sql
CREATE TABLE IF NOT EXISTS utime_players (
  steamid64      VARCHAR(20)        NOT NULL,
  total_seconds  BIGINT UNSIGNED    NOT NULL DEFAULT 0,
  updated_at     TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (steamid64),
  KEY idx_total_seconds (total_seconds)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Job Time 

```sql
CREATE TABLE IF NOT EXISTS utime_jobtime (
  steamid64 VARCHAR(20)      NOT NULL,
  job_key   VARCHAR(128)     NOT NULL,
  seconds   BIGINT UNSIGNED  NOT NULL DEFAULT 0,
  PRIMARY KEY (steamid64, job_key),
  INDEX (job_key),
  CONSTRAINT fk_utime_player
    FOREIGN KEY (steamid64) REFERENCES utime_players(steamid64)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

```

--- 

## Installation (GMod Server)

1. Copy the addon script ``(e.g. garrysmod/lua/autorun/server/sv_utime_mysql.lua)``.
2. Install a MySQL module (e.g. mysqloo or tmysql4).
3. Configure DB credentials in the script.
4. Restart the server.

The script updates ``total_seconds`` periodically and on disconnect; job time is updated whenever your gamemode switches jobs.


---

## Queries for Websites/Dashboards

### Leaderboard (Top 50 by total time)
```javascript
const [rows] = await db.query(
  "SELECT steamid64, total_seconds FROM utime_players ORDER BY total_seconds DESC LIMIT 50"
);
// rows = [{ steamid64: "7656119...", total_seconds: 123456 }, ...]
```

### NEW: Per-player job breakdown (parametrized)

```javascript
const [rows] = await db.query(
  "SELECT job_key, seconds FROM utime_jobtime WHERE steamid64 = ? ORDER BY seconds DESC",
  [req.user.id] // or the SteamID64 you want to query
);
// rows = [{ job_key: "Police", seconds: 53211 }, ...]
```

---

## API Examples (Express.js)

```javascript
// GET /api/utime/top  → total time leaderboard
app.get("/api/utime/top", async (_req, res) => {
  const [rows] = await db.query(
    "SELECT steamid64, total_seconds FROM utime_players ORDER BY total_seconds DESC LIMIT 50"
  );
  res.json(rows);
});

// GET /api/utime/:steamid64/jobs  → job time for a player
app.get("/api/utime/:steamid64/jobs", async (req, res) => {
  const [rows] = await db.query(
    "SELECT job_key, seconds FROM utime_jobtime WHERE steamid64 = ? ORDER BY seconds DESC",
    [req.params.steamid64]
  );
  res.json(rows);
});

```
---

## Other Language Examples

### PHP (PDO)

```php
// Leaderboard
$stmt = $pdo->query("SELECT steamid64, total_seconds FROM utime_players ORDER BY total_seconds DESC LIMIT 50");
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

// Per-player jobs (parametrized)
$stmt2 = $pdo->prepare("SELECT job_key, seconds FROM utime_jobtime WHERE steamid64 = ? ORDER BY seconds DESC");
$stmt2->execute([$steamid64]);
$jobs = $stmt2->fetchAll(PDO::FETCH_ASSOC);

echo json_encode(["leaderboard" => $rows, "jobs" => $jobs]);
```

---

## Best Practices
- Least privilege: Website user only needs ``SELECT`` on both tables.
- Separate creds: WRITE (game server) vs READ (web).
- Indices: ``PRIMARY KEY (steamid64, job_key)`` and ``INDEX(job_key)`` make lookups fast.
- Consistency: Use canonical ``job_key`` names; avoid renames if possible.
- Backups: Tables are small; daily dumps are usually sufficient.

---
## Used By

This project is used by the following companies:

- [Solve SCP:RP Germany](https://discord.gg/AnBNDzGRn5)

