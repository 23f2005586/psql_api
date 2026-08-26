-- Playground schema for SQL learning.
-- Runs once when the PostgreSQL data volume is first created.
-- Tables are owned by the non-superuser "playground" role.

CREATE TABLE IF NOT EXISTS departments (
  id   SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS employees (
  id         SERIAL PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  department VARCHAR(100) NOT NULL,
  salary     INTEGER NOT NULL CHECK (salary >= 0)
);

CREATE TABLE IF NOT EXISTS customers (
  id   SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  city VARCHAR(100) NOT NULL
);

INSERT INTO departments (name) VALUES
  ('IT'),
  ('HR'),
  ('Sales'),
  ('Finance')
ON CONFLICT (name) DO NOTHING;

INSERT INTO employees (name, department, salary) VALUES
  ('John', 'IT', 60000),
  ('Sarah', 'HR', 52000),
  ('Mike', 'Sales', 48000),
  ('Priya', 'IT', 72000),
  ('Alex', 'Finance', 65000),
  ('Emma', 'Sales', 51000),
  ('Raj', 'IT', 68000),
  ('Lisa', 'HR', 54000);

INSERT INTO customers (name, city) VALUES
  ('Acme Corp', 'Mumbai'),
  ('Globex', 'Delhi'),
  ('Initech', 'Bengaluru'),
  ('Umbrella', 'Hyderabad'),
  ('Stark Industries', 'Pune');

ALTER TABLE departments OWNER TO playground;
ALTER TABLE employees OWNER TO playground;
ALTER TABLE customers OWNER TO playground;

-- Sequences used by SERIAL columns
ALTER SEQUENCE departments_id_seq OWNER TO playground;
ALTER SEQUENCE employees_id_seq OWNER TO playground;
ALTER SEQUENCE customers_id_seq OWNER TO playground;

GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON ALL TABLES IN SCHEMA public TO playground;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO playground;
