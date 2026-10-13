-- ============================================================
--  EventGuard — Seed Data
--  "Aatmatrisha" event with Concert + Stand-up Comedy
--
--  LEARNING NOTE:
--  Seed data populates the database with realistic starting data
--  so you can develop and test without creating everything manually.
--  Run this AFTER schema.sql.
-- ============================================================

-- ============================================================
-- 1. USERS
--    We create 4 users — one per role — to test every part of the app.
--
--  LEARNING NOTE on password_hash:
--  We never store plain passwords. bcrypt hashes 'password123'
--  into a long unreadable string. The app compares hashes at login.
--  Below we use a pre-generated bcrypt hash of 'password123'.
-- ============================================================

INSERT INTO users (name, email, password_hash, role) VALUES
-- The platform administrator
('Admin User',      'admin@eventguard.com',      '$2b$10$rOzJ6PWFQEk3y8OECP3jT.tYx9r8MVuFvC8PTNA6aRbnOy1gVqDSO', 'admin'),

-- The event organizer (runs Aatmatrisha)
('Rohan Mehta',     'rohan@aatmatrisha.com',     '$2b$10$rOzJ6PWFQEk3y8OECP3jT.tYx9r8MVuFvC8PTNA6aRbnOy1gVqDSO', 'organizer'),

-- A regular attendee who will buy tickets
('Priya Sharma',    'priya@example.com',         '$2b$10$rOzJ6PWFQEk3y8OECP3jT.tYx9r8MVuFvC8PTNA6aRbnOy1gVqDSO', 'attendee'),

-- Gate staff who scans QR codes at the entrance
('Amit Kumar',      'amit.gate@eventguard.com',  '$2b$10$rOzJ6PWFQEk3y8OECP3jT.tYx9r8MVuFvC8PTNA6aRbnOy1gVqDSO', 'gate_staff');

-- user_id auto-assigned: admin=1, rohan=2, priya=3, amit=4


-- ============================================================
-- 2. VENUE
--    Aatmatrisha is held at one venue with two stages/halls.
--    In a real app you'd have separate venue rows for each hall,
--    but here we simplify to one venue for the whole event.
-- ============================================================

INSERT INTO venues (name, address, city, capacity) VALUES
('Bangalore Palace Grounds', 'Palace Grounds, Bellary Road, Sadashivanagar', 'Bangalore', 5000);

-- venue_id = 1


-- ============================================================
-- 3. EVENTS
--    Two sub-events under the Aatmatrisha festival.
--    organizer_id = 2 (Rohan Mehta)
--    venue_id     = 1 (Palace Grounds)
--
--  LEARNING NOTE on timestamps:
--  TIMESTAMPTZ = timestamp WITH time zone.
--  We store everything in UTC and display in local timezone in the UI.
--  '2026-12-20 18:00:00+05:30' = 6 PM IST on Dec 20.
-- ============================================================

INSERT INTO events (organizer_id, venue_id, title, description, category, start_time, end_time, status)
VALUES
(
    2,   -- rohan
    1,   -- palace grounds
    'Aatmatrisha — The Grand Concert',
    'An electrifying live music night featuring top Bollywood and Indie artists. '
    'Expect dazzling light shows, live bands, and an unforgettable night under the stars '
    'at Bangalore Palace Grounds.',
    'concert',
    '2026-12-20 18:00:00+05:30',    -- 6 PM IST
    '2026-12-20 23:00:00+05:30',    -- 11 PM IST
    'published'
),
(
    2,   -- rohan
    1,   -- palace grounds
    'Aatmatrisha — Stand-up Comedy Night',
    'Laugh till your stomach hurts! Top stand-up comedians from across India perform '
    'their newest sets. A perfect evening of wit, satire, and unstoppable laughter.',
    'comedy',
    '2026-12-21 19:00:00+05:30',    -- 7 PM IST next day
    '2026-12-21 22:00:00+05:30',    -- 10 PM IST
    'published'
);

-- event_id = 1 → Concert
-- event_id = 2 → Comedy Night

-- LEARNING NOTE: The search_vector column updates AUTOMATICALLY
-- because of the trigger we wrote in schema.sql. You don't need
-- to populate it manually.


-- ============================================================
-- 4. TICKET TYPES
--    Each event has VIP and General tiers.
--    Price in INR (₹). quantity_total = how many tickets available.
-- ============================================================

INSERT INTO ticket_types (event_id, name, price, quantity_total) VALUES
-- Concert tickets
(1, 'VIP',     2000.00, 200),     -- 200 VIP concert tickets @ ₹2000
(1, 'General',  500.00, 2000),    -- 2000 General concert tickets @ ₹500

-- Comedy Night tickets
(2, 'VIP',     1500.00, 150),     -- 150 VIP comedy tickets @ ₹1500
(2, 'General',  300.00, 1500);    -- 1500 General comedy tickets @ ₹300

-- ticket_type_id: 1=Concert VIP, 2=Concert General, 3=Comedy VIP, 4=Comedy General


-- ============================================================
-- 5. SAMPLE PURCHASE (using our stored procedure)
--    Priya (user_id=3) buys 2 General Concert tickets.
--
--  LEARNING NOTE:
--  SELECT purchase_ticket(...) calls the stored procedure we wrote
--  in schema.sql. It:
--    - Creates an Order
--    - Creates an OrderItem (qty=2)
--    - Creates 2 Ticket rows (each with a unique QR UUID)
--    - Creates a Payment record
--    - Returns the order_id
-- ============================================================

SELECT purchase_ticket(
    3,          -- p_user_id      = Priya
    2,          -- p_ticket_type_id = Concert General
    2,          -- p_quantity     = 2 tickets
    '103.21.5.9'::INET,    -- p_ip (simulated)
    'fp-abc123'            -- p_device_fp (simulated browser fingerprint)
);
-- This should return order_id = 1


-- ============================================================
-- 6. SAMPLE FRAUD FLAG (for admin dashboard demo)
--    Manually flag order 1 with a medium risk score.
--    In the real app the fraud engine writes this automatically.
-- ============================================================

INSERT INTO fraud_flags (order_id, flag_reason, risk_score) VALUES
(1, 'Velocity anomaly: 3 checkout attempts in 30 seconds from same IP', 45.0);

-- risk_score = 45 → below 80, so order stays 'confirmed' (not auto-held)
-- The admin can review it in the fraud_review_queue view.


-- ============================================================
-- 7. VERIFICATION QUERIES
--    Run these to confirm everything was inserted correctly.
-- ============================================================

-- See all events with their ticket types
SELECT
    e.title        AS event,
    tt.name        AS ticket_tier,
    tt.price,
    tt.quantity_total AS total,
    tt.quantity_sold  AS sold,
    (tt.quantity_total - tt.quantity_sold) AS remaining
FROM   events e
JOIN   ticket_types tt ON tt.event_id = e.event_id
ORDER  BY e.event_id, tt.price DESC;

-- See the event sales summary (uses our VIEW)
SELECT * FROM event_sales_summary;

-- See fraud review queue (uses our VIEW)
SELECT * FROM fraud_review_queue;

-- See Priya's tickets with their QR codes
SELECT
    t.ticket_id,
    t.qr_code,
    t.status,
    tt.name   AS ticket_type,
    e.title   AS event
FROM   tickets     t
JOIN   order_items oi ON oi.order_item_id = t.order_item_id
JOIN   ticket_types tt ON tt.ticket_type_id = oi.ticket_type_id
JOIN   events      e  ON e.event_id = tt.event_id
WHERE  oi.order_id = 1;
