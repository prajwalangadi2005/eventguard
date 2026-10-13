-- ============================================================
--  EventGuard — PostgreSQL Schema
--  Phase 1: Core Tables (DDL)
--
--  LEARNING NOTE:
--  DDL = Data Definition Language — commands that CREATE
--  the structure of your database (tables, indexes, views).
--  DML = Data Manipulation Language — INSERT, UPDATE, SELECT
--  (we use that in seed.sql)
-- ============================================================

-- Enable the pgvector extension (needed for fraud + search vectors later)
-- LEARNING NOTE: Extensions add new data types / functions to PostgreSQL.
-- "vector" type lets us store ML embeddings (arrays of floats).
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- 1. USERS
--    Everyone who touches the system is a User.
--    role decides what they can do (RBAC = Role Based Access Control)
-- ============================================================
CREATE TYPE user_role AS ENUM ('admin', 'organizer', 'attendee', 'gate_staff');

CREATE TABLE users (
    user_id          SERIAL PRIMARY KEY,
    name             VARCHAR(100)  NOT NULL,
    email            VARCHAR(255)  UNIQUE NOT NULL,      -- no two accounts share an email
    password_hash    TEXT          NOT NULL,             -- bcrypt hash, never plain text
    role             user_role     NOT NULL DEFAULT 'attendee',
    device_fingerprint_hash TEXT,                        -- browser fingerprint for fraud detection
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- LEARNING NOTE: INDEX speeds up queries that filter/sort by a column.
-- We always index foreign keys and columns used in WHERE clauses.
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_role  ON users(role);


-- ============================================================
-- 2. VENUES
--    Physical location where events happen.
-- ============================================================
CREATE TABLE venues (
    venue_id   SERIAL PRIMARY KEY,
    name       VARCHAR(150) NOT NULL,
    address    TEXT         NOT NULL,
    city       VARCHAR(100) NOT NULL,
    capacity   INTEGER      NOT NULL CHECK (capacity > 0)  -- must have at least 1 seat
);


-- ============================================================
-- 3. EVENTS
--    An event belongs to one organizer and one venue.
--    search_vector is a special PostgreSQL type for full-text search.
-- ============================================================
CREATE TYPE event_status AS ENUM ('draft', 'published', 'cancelled');

CREATE TABLE events (
    event_id      SERIAL PRIMARY KEY,
    organizer_id  INTEGER      NOT NULL REFERENCES users(user_id)  ON DELETE RESTRICT,
    venue_id      INTEGER      NOT NULL REFERENCES venues(venue_id) ON DELETE RESTRICT,
    title         VARCHAR(200) NOT NULL,
    description   TEXT,
    category      VARCHAR(100),                        -- e.g., 'concert', 'comedy', 'workshop'
    start_time    TIMESTAMPTZ  NOT NULL,
    end_time      TIMESTAMPTZ  NOT NULL,
    status        event_status NOT NULL DEFAULT 'draft',
    -- LEARNING NOTE: tsvector is PostgreSQL's built-in full-text search type.
    -- It stores a pre-processed version of text for fast keyword matching.
    search_vector TSVECTOR,
    -- Vector embedding for semantic search (pgvector) — populated by the API layer
    embedding     VECTOR(384),

    CONSTRAINT chk_event_times CHECK (end_time > start_time)
);

-- GIN index makes full-text search fast (inverted index structure)
CREATE INDEX idx_events_search_vector ON events USING GIN(search_vector);
-- HNSW index makes vector similarity search fast
CREATE INDEX idx_events_embedding     ON events USING hnsw(embedding vector_cosine_ops);
CREATE INDEX idx_events_organizer     ON events(organizer_id);
CREATE INDEX idx_events_venue         ON events(venue_id);
CREATE INDEX idx_events_status        ON events(status);

-- TRIGGER: auto-update search_vector when title/description/category changes
-- LEARNING NOTE: A trigger fires automatically when something happens to a table.
-- This one keeps search_vector in sync without the app needing to do it manually.
CREATE OR REPLACE FUNCTION update_event_search_vector()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', COALESCE(NEW.title, '')),       'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.description, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.category, '')),    'C');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_event_search_vector
BEFORE INSERT OR UPDATE ON events
FOR EACH ROW EXECUTE FUNCTION update_event_search_vector();


-- ============================================================
-- 4. TICKET TYPES
--    Each event can have multiple ticket types (VIP, General, etc.)
--    quantity_sold is maintained by a trigger (see below).
-- ============================================================
CREATE TABLE ticket_types (
    ticket_type_id  SERIAL PRIMARY KEY,
    event_id        INTEGER      NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
    name            VARCHAR(100) NOT NULL,              -- e.g., 'VIP', 'General'
    price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    quantity_total  INTEGER      NOT NULL CHECK (quantity_total > 0),
    quantity_sold   INTEGER      NOT NULL DEFAULT 0
                    CHECK (quantity_sold >= 0 AND quantity_sold <= quantity_total)
);

CREATE INDEX idx_ticket_types_event ON ticket_types(event_id);


-- ============================================================
-- 5. ORDERS
--    Created when a user starts the checkout process.
--    status moves: pending → confirmed → (cancelled | refunded)
-- ============================================================
CREATE TYPE order_status AS ENUM ('pending', 'confirmed', 'cancelled', 'refunded', 'pending_review');

CREATE TABLE orders (
    order_id          SERIAL PRIMARY KEY,
    user_id           INTEGER      NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    order_time        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    total_amount      NUMERIC(10,2) NOT NULL CHECK (total_amount >= 0),
    status            order_status NOT NULL DEFAULT 'pending',
    ip_address        INET,                            -- stores IP like 192.168.1.1
    device_fingerprint TEXT                            -- browser fingerprint string
);

CREATE INDEX idx_orders_user   ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_ip     ON orders(ip_address);


-- ============================================================
-- 6. ORDER ITEMS
--    A single order can have items from multiple ticket types.
--    Example: 2x VIP Concert + 1x General Comedy = 1 order, 2 items
-- ============================================================
CREATE TABLE order_items (
    order_item_id   SERIAL PRIMARY KEY,
    order_id        INTEGER      NOT NULL REFERENCES orders(order_id)           ON DELETE CASCADE,
    ticket_type_id  INTEGER      NOT NULL REFERENCES ticket_types(ticket_type_id) ON DELETE RESTRICT,
    quantity        INTEGER      NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0)
    -- unit_price is snapshotted at purchase time — price may change later
);

CREATE INDEX idx_order_items_order       ON order_items(order_id);
CREATE INDEX idx_order_items_ticket_type ON order_items(ticket_type_id);


-- ============================================================
-- 7. TICKETS
--    One physical ticket per seat/entry.
--    Each OrderItem of quantity N generates N Ticket rows.
--    qr_code is a unique UUID — this IS the QR code value.
-- ============================================================
CREATE TYPE ticket_status AS ENUM ('valid', 'used', 'cancelled', 'flagged');

CREATE TABLE tickets (
    ticket_id     SERIAL PRIMARY KEY,
    order_item_id INTEGER     NOT NULL REFERENCES order_items(order_item_id) ON DELETE CASCADE,
    qr_code       UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    status        ticket_status NOT NULL DEFAULT 'valid',
    issued_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_tickets_order_item ON tickets(order_item_id);
CREATE INDEX idx_tickets_qr_code    ON tickets(qr_code);   -- gate staff will scan this
CREATE INDEX idx_tickets_status     ON tickets(status);


-- ============================================================
-- 8. PAYMENTS
--    One payment per order (1:1 relationship).
--    In our app we mock/sandbox this — no real money moves.
-- ============================================================
CREATE TYPE payment_status AS ENUM ('pending', 'success', 'failed', 'refunded');

CREATE TABLE payments (
    payment_id      SERIAL PRIMARY KEY,
    order_id        INTEGER      NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE CASCADE,
    amount          NUMERIC(10,2) NOT NULL,
    status          payment_status NOT NULL DEFAULT 'pending',
    transaction_ref VARCHAR(255),                      -- mock reference string
    paid_at         TIMESTAMPTZ
);

CREATE INDEX idx_payments_order ON payments(order_id);


-- ============================================================
-- 9. FRAUD FLAGS
--    Written by the fraud engine when an order looks suspicious.
--    Admin reviews these and marks confirmed_fraud or false_positive.
-- ============================================================
CREATE TYPE review_status AS ENUM ('pending', 'confirmed_fraud', 'false_positive');

CREATE TABLE fraud_flags (
    flag_id         SERIAL PRIMARY KEY,
    order_id        INTEGER      NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    flag_reason     TEXT         NOT NULL,              -- human-readable reason
    risk_score      NUMERIC(5,2) NOT NULL CHECK (risk_score BETWEEN 0 AND 100),
    flagged_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    reviewed_by     INTEGER      REFERENCES users(user_id),  -- NULL until admin reviews
    review_status   review_status NOT NULL DEFAULT 'pending'
);

CREATE INDEX idx_fraud_flags_order         ON fraud_flags(order_id);
CREATE INDEX idx_fraud_flags_review_status ON fraud_flags(review_status);


-- ============================================================
-- 10. CHECK-INS
--     Written by gate staff when they scan a QR code at the door.
--     UNIQUE on ticket_id → a ticket can only be checked in ONCE.
-- ============================================================
CREATE TABLE check_ins (
    checkin_id    SERIAL PRIMARY KEY,
    ticket_id     INTEGER     NOT NULL UNIQUE REFERENCES tickets(ticket_id) ON DELETE CASCADE,
    checkin_time  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    gate_staff_id INTEGER     NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT
);

CREATE INDEX idx_checkins_ticket     ON check_ins(ticket_id);
CREATE INDEX idx_checkins_gate_staff ON check_ins(gate_staff_id);


-- ============================================================
-- 11. ORDER RISK VECTORS  (Phase 6 — Vector DB)
--     Stores the behavioral feature vector for each order.
--     Used to compare new orders against known fraud patterns.
-- ============================================================
CREATE TABLE order_risk_vectors (
    order_id   INTEGER      NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE CASCADE,
    vector     VECTOR(6),                             -- 6 behavioral features (see Phase 6)
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE fraud_reference_vectors (
    ref_id     SERIAL PRIMARY KEY,
    label      TEXT         NOT NULL,                 -- description of fraud pattern
    vector     VECTOR(6)    NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_order_risk_vectors_hnsw
    ON order_risk_vectors USING hnsw(vector vector_cosine_ops);

CREATE INDEX idx_fraud_ref_vectors_hnsw
    ON fraud_reference_vectors USING hnsw(vector vector_cosine_ops);


-- ============================================================
-- TRIGGERS — Business Logic enforced at the DB level
-- ============================================================

-- TRIGGER 1: When a Ticket is inserted, increment quantity_sold on TicketType
-- LEARNING NOTE: This uses a trigger so that quantity_sold is ALWAYS accurate,
-- even if someone bypasses the app and inserts directly into the DB.
CREATE OR REPLACE FUNCTION increment_quantity_sold()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE ticket_types
    SET    quantity_sold = quantity_sold + 1
    WHERE  ticket_type_id = (
        SELECT ticket_type_id FROM order_items WHERE order_item_id = NEW.order_item_id
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_increment_quantity_sold
AFTER INSERT ON tickets
FOR EACH ROW EXECUTE FUNCTION increment_quantity_sold();


-- TRIGGER 2: Prevent overselling — raise an error if sold >= total BEFORE insert
CREATE OR REPLACE FUNCTION check_ticket_availability()
RETURNS TRIGGER AS $$
DECLARE
    v_sold  INTEGER;
    v_total INTEGER;
BEGIN
    SELECT quantity_sold, quantity_total
    INTO   v_sold, v_total
    FROM   ticket_types
    WHERE  ticket_type_id = (
        SELECT ticket_type_id FROM order_items WHERE order_item_id = NEW.order_item_id
    );

    IF v_sold >= v_total THEN
        RAISE EXCEPTION 'Tickets sold out for this ticket type (sold=%, total=%)', v_sold, v_total;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_ticket_availability
BEFORE INSERT ON tickets
FOR EACH ROW EXECUTE FUNCTION check_ticket_availability();


-- TRIGGER 3: If a fraud flag has risk_score > 80, auto-hold the order
CREATE OR REPLACE FUNCTION auto_hold_high_risk_order()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.risk_score > 80 THEN
        UPDATE orders
        SET    status = 'pending_review'
        WHERE  order_id = NEW.order_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auto_hold_high_risk
AFTER INSERT ON fraud_flags
FOR EACH ROW EXECUTE FUNCTION auto_hold_high_risk_order();


-- ============================================================
-- STORED PROCEDURES
-- ============================================================

-- PROCEDURE: purchase_ticket
-- LEARNING NOTE: A stored procedure bundles multiple SQL statements
-- into one atomic transaction. Either ALL steps succeed, or NONE do.
-- This prevents the horror scenario: payment deducted but ticket not issued.
CREATE OR REPLACE FUNCTION purchase_ticket(
    p_user_id       INTEGER,
    p_ticket_type_id INTEGER,
    p_quantity      INTEGER,
    p_ip            INET DEFAULT NULL,
    p_device_fp     TEXT DEFAULT NULL
)
RETURNS INTEGER   -- returns the new order_id
LANGUAGE plpgsql AS $$
DECLARE
    v_price       NUMERIC(10,2);
    v_total       NUMERIC(10,2);
    v_order_id    INTEGER;
    v_item_id     INTEGER;
    i             INTEGER;
BEGIN
    -- Step 1: Get the ticket price (lock the row to prevent race conditions)
    SELECT price INTO v_price
    FROM   ticket_types
    WHERE  ticket_type_id = p_ticket_type_id
    FOR UPDATE;                                        -- row-level lock

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket type % not found', p_ticket_type_id;
    END IF;

    v_total := v_price * p_quantity;

    -- Step 2: Create the Order
    INSERT INTO orders (user_id, total_amount, status, ip_address, device_fingerprint)
    VALUES (p_user_id, v_total, 'pending', p_ip, p_device_fp)
    RETURNING order_id INTO v_order_id;

    -- Step 3: Create the OrderItem
    INSERT INTO order_items (order_id, ticket_type_id, quantity, unit_price)
    VALUES (v_order_id, p_ticket_type_id, p_quantity, v_price)
    RETURNING order_item_id INTO v_item_id;

    -- Step 4: Generate individual Tickets (one per seat)
    -- The BEFORE trigger will catch overselling here
    FOR i IN 1..p_quantity LOOP
        INSERT INTO tickets (order_item_id) VALUES (v_item_id);
    END LOOP;

    -- Step 5: Create a pending payment record
    INSERT INTO payments (order_id, amount, status)
    VALUES (v_order_id, v_total, 'pending');

    -- Step 6: Mark order as confirmed
    UPDATE orders SET status = 'confirmed' WHERE order_id = v_order_id;
    UPDATE payments SET status = 'success', paid_at = NOW(),
                        transaction_ref = 'MOCK-' || v_order_id
    WHERE  order_id = v_order_id;

    RETURN v_order_id;
END;
$$;


-- ============================================================
-- VIEWS
-- LEARNING NOTE: A VIEW is a saved SELECT query. You query it
-- like a table, but it always shows fresh data.
-- ============================================================

-- View 1: Sales summary per event (used in organizer dashboard)
CREATE OR REPLACE VIEW event_sales_summary AS
SELECT
    e.event_id,
    e.title            AS event_title,
    e.status           AS event_status,
    tt.ticket_type_id,
    tt.name            AS ticket_type_name,
    tt.price,
    tt.quantity_total,
    tt.quantity_sold,
    (tt.quantity_total - tt.quantity_sold) AS remaining,
    (tt.quantity_sold * tt.price)          AS revenue
FROM   events      e
JOIN   ticket_types tt ON tt.event_id = e.event_id;


-- View 2: Fraud review queue (admin dashboard)
CREATE OR REPLACE VIEW fraud_review_queue AS
SELECT
    ff.flag_id,
    ff.order_id,
    o.user_id,
    u.name     AS user_name,
    u.email    AS user_email,
    ff.flag_reason,
    ff.risk_score,
    ff.flagged_at,
    ff.review_status,
    o.total_amount,
    o.ip_address
FROM   fraud_flags ff
JOIN   orders  o ON o.order_id = ff.order_id
JOIN   users   u ON u.user_id  = o.user_id
WHERE  ff.review_status = 'pending'
ORDER  BY ff.risk_score DESC;              -- highest risk shown first
