'use strict';

require('dotenv').config();

const cors = require('cors');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { Pool } = require('pg');

const MAX_ROWS = 1000;
const STATEMENT_TIMEOUT_MS = 3000;

const {
  API_KEY,
  PGHOST = 'postgres',
  PGPORT = '5432',
  PGDATABASE = 'playground',
  PGUSER = 'playground',
  PGPASSWORD,
  PORT = '3000',
  HOST = '0.0.0.0',
  RATE_LIMIT_WINDOW_MS = '60000',
  RATE_LIMIT_MAX = '60',
  BODY_LIMIT = '16kb',
} = process.env;

function requireEnv(name, value) {
  if (!value || String(value).trim() === '') {
    console.error(`Missing required environment variable: ${name}`);
    process.exit(1);
  }
}

requireEnv('API_KEY', API_KEY);
requireEnv('PGPASSWORD', PGPASSWORD);

if (API_KEY === 'change-me-to-a-long-random-string') {
  console.warn('WARNING: API_KEY is still the example default. Change it before production use.');
}

const app = express();

app.disable('x-powered-by');
app.set('trust proxy', 1);

app.use(cors());
app.use(express.json({ limit: BODY_LIMIT }));

app.use(
  rateLimit({
    windowMs: Number(RATE_LIMIT_WINDOW_MS) || 60000,
    max: Number(RATE_LIMIT_MAX) || 60,
    standardHeaders: true,
    legacyHeaders: false,
    message: { success: false, error: 'Too many requests. Please try again later.' },
  })
);

const pool = new Pool({
  host: PGHOST,
  port: Number(PGPORT) || 5432,
  database: PGDATABASE,
  user: PGUSER,
  password: PGPASSWORD,
  max: 5,
  idleTimeoutMillis: 10000,
  connectionTimeoutMillis: 5000,
  // Never connect as a superuser; credentials are the playground role only.
});

function sanitizeErrorMessage(err) {
  if (!err) return 'Query failed';
  let message = err.message || 'Query failed';
  // Strip anything that might accidentally echo secrets from env/config.
  if (PGPASSWORD) {
    message = message.split(PGPASSWORD).join('[redacted]');
  }
  if (API_KEY) {
    message = message.split(API_KEY).join('[redacted]');
  }
  return message;
}

function requireApiKey(req, res, next) {
  const header = req.get('authorization') || '';
  const match = header.match(/^Bearer\s+(.+)$/i);
  const key = match ? match[1].trim() : req.get('x-api-key');

  if (!key || key !== API_KEY) {
    return res.status(401).json({
      success: false,
      error: 'Unauthorized. Provide a valid API key.',
    });
  }
  return next();
}

app.get('/health', (_req, res) => {
  res.json({ ok: true });
});

app.post('/api/run-sql', requireApiKey, async (req, res) => {
  const { query } = req.body || {};

  if (typeof query !== 'string' || query.trim() === '') {
    return res.status(400).json({
      success: false,
      error: 'Request body must include a non-empty string field "query".',
    });
  }

  const client = await pool.connect();

  try {
    await client.query('BEGIN');
    // Parameterized SET keeps timeout under our control (not user SQL).
    await client.query('SET LOCAL statement_timeout = $1', [`${STATEMENT_TIMEOUT_MS}`]);

    const result = await client.query(query);

    // Always discard mutations so the shared playground stays clean.
    await client.query('ROLLBACK');

    const fields = result.fields || [];
    const columns = fields.map((f) => f.name);
    const allRows = result.rows || [];
    const limited = allRows.slice(0, MAX_ROWS);
    const rows = limited.map((row) => columns.map((col) => row[col]));

    return res.json({
      success: true,
      columns,
      rows,
      rowCount: rows.length,
      truncated: allRows.length > MAX_ROWS,
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_) {
      // ignore rollback errors after a failed query
    }

    const status = err && err.code === '57014' ? 408 : 400;
    return res.status(status).json({
      success: false,
      error: sanitizeErrorMessage(err),
    });
  } finally {
    client.release();
  }
});

app.use((err, _req, res, _next) => {
  if (err && err.type === 'entity.too.large') {
    return res.status(413).json({
      success: false,
      error: 'Request body too large.',
    });
  }
  console.error('Unhandled error:', sanitizeErrorMessage(err));
  return res.status(500).json({
    success: false,
    error: 'Internal server error.',
  });
});

const server = app.listen(Number(PORT) || 3000, HOST, () => {
  console.log(`SQL Runner API listening on ${HOST}:${PORT}`);
  console.log(`Connected target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}`);
});

function shutdown(signal) {
  console.log(`${signal} received, shutting down...`);
  server.close(async () => {
    try {
      await pool.end();
    } catch (_) {
      // ignore
    }
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
