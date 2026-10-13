# EventGuard — Local Event & Ticketing Platform with Fraud Detection
## DBMS Level 3 Project — Implementation Plan

---

## 1. Problem Statement & Motivation

Local event organizers (concerts, workshops, meetups, college fests) lose revenue and trust to ticket fraud: bots buying entire ticket blocks in seconds, duplicate/cloned QR tickets being resold, stolen-card purchases resulting in chargebacks, and fake accounts gaming discount codes. Most student ticketing projects are simple CRUD (create event → book ticket → pay) with no fraud awareness.

**EventGuard** goes beyond CRUD by combining transactional ticket sales with a **behavioral fraud-scoring engine** that flags suspicious orders in real time using both rule-based checks and **vector similarity search** against known fraud patterns — directly satisfying the "not a simple CRUD application" and "≥2 database paradigms" requirements in a way that's justified by the problem, not bolted on.

**Objectives**
- Let organizers create/manage events, venues, ticket types and view sales analytics.
- Let attendees discover, search, and book tickets with QR-based entry.
- Detect and flag suspicious orders (bot velocity, device/IP anomalies, pattern-matching against past fraud) before/at payment confirmation.
- Provide gate staff a check-in interface that rejects reused/fraudulent QR codes.

**Scope**
- In scope: event listing/search, ticket purchase flow, QR issuance & check-in, organizer analytics dashboard, fraud scoring + admin review queue, role-based auth.
- Out of scope: real payment gateway settlement (use a mocked/sandbox payment step), native mobile app.

---

## 2. Team Formation (2 members)

| Member | Primary Responsibility | Also Contributes To |
|---|---|---|
| **Member A** | SQL schema design (PostgreSQL), DDL, transactions/triggers/stored procedures, backend order & payment API routes | Fraud rule-engine logic, testing |
| **Member B** | NoSQL (MongoDB) activity-log model, Vector DB (pgvector/Qdrant) fraud-embedding + semantic search, Next.js frontend (search, checkout, dashboards) | Auth/RBAC, documentation, deployment |

Git commits should be tagged/attributed per feature so individual contribution is visible (see §11).

---

## 3. Database Paradigm Choice & Justification

The brief requires **≥2 paradigms**; EventGuard uses **three**, each justified by data shape — not for technology's sake:

| Paradigm | Tech | Why this data belongs here |
|---|---|---|
| **SQL** | PostgreSQL | Core transactional data (users, events, orders, tickets, payments) is highly structured, relationally connected, and needs ACID guarantees so tickets are never oversold or double-issued. |
| **NoSQL (document)** | MongoDB | High-volume, semi-structured, schema-flexible **activity/click logs** (page views, checkout attempts, device fingerprints) used for behavioral fraud signals — write-heavy, rarely joined, doesn't need a rigid relational schema. |
| **Vector** | PostgreSQL + `pgvector` (or Qdrant) | (a) Semantic **event search** ("chill acoustic night downtown") needs embedding similarity, not keyword match. (b) **Fraud pattern matching**: each order's behavioral fingerprint is encoded as a vector and compared via cosine similarity to vectors of previously confirmed fraudulent orders — a relational `WHERE` clause can't express "is this behavior similar to past fraud." |

---

## 4. SQL Database Design (PostgreSQL)

### 4.1 ER Diagram — Entities & Relationships (to be drawn formally, structure below)

- **Users** (1) —— (M) **Events** [as organizer]
- **Users** (1) —— (M) **Orders**
- **Venues** (1) —— (M) **Events**
- **Events** (1) —— (M) **TicketTypes**
- **TicketTypes** (1) —— (M) **OrderItems**
- **Orders** (1) —— (M) **OrderItems**
- **Orders** (1) —— (1) **Payments**
- **OrderItems** (1) —— (M) **Tickets**
- **Tickets** (1) —— (0..1) **CheckIns**
- **Orders** (1) —— (0..M) **FraudFlags**
- **Users** (1) —— (M) **FraudFlags** [reviewed_by, admin]

### 4.2 Table Design (entities, keys, constraints)

**Users**
`user_id (PK)`, `name`, `email (UNIQUE, NOT NULL)`, `password_hash`, `role (ENUM: admin, organizer, attendee, gate_staff)`, `device_fingerprint_hash`, `created_at`

**Venues**
`venue_id (PK)`, `name`, `address`, `city`, `capacity (CHECK > 0)`

**Events**
`event_id (PK)`, `organizer_id (FK→Users, ON DELETE RESTRICT)`, `venue_id (FK→Venues)`, `title`, `description`, `category`, `start_time`, `end_time (CHECK end_time > start_time)`, `status (ENUM: draft, published, cancelled)`, `search_vector (tsvector, for full-text search)`

**TicketTypes**
`ticket_type_id (PK)`, `event_id (FK→Events, ON DELETE CASCADE)`, `name`, `price (CHECK ≥ 0)`, `quantity_total (CHECK > 0)`, `quantity_sold (CHECK ≥ 0 AND ≤ quantity_total)`

**Orders**
`order_id (PK)`, `user_id (FK→Users)`, `order_time`, `total_amount`, `status (ENUM: pending, confirmed, cancelled, refunded)`, `ip_address`, `device_fingerprint`

**OrderItems**
`order_item_id (PK)`, `order_id (FK→Orders, ON DELETE CASCADE)`, `ticket_type_id (FK→TicketTypes)`, `quantity (CHECK > 0)`, `unit_price`

**Tickets**
`ticket_id (PK)`, `order_item_id (FK→OrderItems, ON DELETE CASCADE)`, `qr_code (UNIQUE, NOT NULL)`, `status (ENUM: valid, used, cancelled, flagged)`, `issued_at`

**Payments**
`payment_id (PK)`, `order_id (FK→Orders, UNIQUE)`, `amount`, `status (ENUM: pending, success, failed, refunded)`, `transaction_ref`, `paid_at`

**FraudFlags**
`flag_id (PK)`, `order_id (FK→Orders)`, `flag_reason`, `risk_score (CHECK BETWEEN 0 AND 100)`, `flagged_at`, `reviewed_by (FK→Users, NULLABLE)`, `review_status (ENUM: pending, confirmed_fraud, false_positive)`

**CheckIns**
`checkin_id (PK)`, `ticket_id (FK→Tickets, UNIQUE)`, `checkin_time`, `gate_staff_id (FK→Users)`

*(Full relational schema with data types + normalization to 3NF goes in the project report, §9.)*

---

## 5. NoSQL Design (MongoDB)

**Why document model:** activity events arrive at high frequency, vary in shape (a "click" event and a "checkout_attempt" event have different fields), and are almost never joined relationally — only aggregated.

**Collections**

```
activity_logs {
  _id, user_id, session_id, action ("view_event"|"add_to_cart"|"checkout_attempt"|...),
  event_id, metadata: { page, referrer },
  ip_address, device_fingerprint, timestamp
}

reviews {
  _id, event_id, user_id, rating (1-5), comment, created_at
}

notifications {
  _id, user_id, type, message, read (bool), created_at
}
```

**Indexes:** compound index on `{user_id, timestamp}` and `{ip_address, timestamp}` for fast fraud-window queries.

**Retrieval strategy:** a MongoDB **aggregation pipeline** groups `activity_logs` by `user_id`/`ip_address` over a rolling 60-second window to compute purchase velocity (e.g., "6 checkout attempts in 10 seconds from 3 different accounts, same device fingerprint") — this feeds directly into the risk score.

---

## 6. Vector Database Design (pgvector or Qdrant)

**Two separate use cases — document both clearly in the report:**

### 6.1 Semantic event search
- **Data embedded:** event `title + description + category`
- **Model:** `sentence-transformers/all-MiniLM-L6-v2` (384-dim), run server-side in the API layer
- **Storage:** `events.embedding vector(384)` column (pgvector) or a Qdrant collection `event_embeddings`
- **Metric:** cosine similarity
- **Retrieval:** top-k nearest neighbors to the user's search-query embedding, merged with full-text results for hybrid search

### 6.2 Fraud pattern similarity (the differentiator)
- **Data embedded:** an engineered **behavioral feature vector** per order — not free text. Features (normalized 0–1): purchase velocity, # distinct payment methods on account, IP/device mismatch score, account age, historical refund/chargeback rate, quantity purchased vs. event average.
- **Storage:** `order_risk_vectors(order_id, vector(N), created_at)`, plus a small labeled set `fraud_reference_vectors` from confirmed past fraud cases.
- **Metric:** cosine similarity via HNSW index.
- **Retrieval strategy:** on each new order, compute its vector → run k-NN against `fraud_reference_vectors` → similarity score is combined (weighted) with the rule-based MongoDB velocity signal → composite `risk_score` written to `FraudFlags`. Score above threshold auto-flags the order for admin review and holds ticket issuance.

---

## 7. SQL Implementation Checklist (DDL)

- `CREATE TABLE` for all 9 entities above, with PK/FK constraints, `CHECK` constraints, `NOT NULL`, `UNIQUE`
- `ALTER TABLE` migrations (e.g., adding `search_vector`, adding indexes post-launch) — keep as versioned migration files
- `DROP`/rollback scripts for each migration
- Indexes: B-tree on all FKs, `GIN` index on `Events.search_vector`, HNSW/IVFFlat on vector columns
- Views: `event_sales_summary` (event, tickets sold, revenue, remaining capacity), `organizer_dashboard_view`

---

## 8. Database Operations (DML) — demonstrate meaningfully, not trivially

- `INSERT`/`UPDATE`/`DELETE`/`SELECT` across the purchase, check-in, and refund flows
- `JOIN`-heavy queries: e.g., "revenue per event per organizer this month" (`Orders ⋈ OrderItems ⋈ TicketTypes ⋈ Events`)
- `GROUP BY` + `HAVING`: events with >50 tickets flagged for fraud review
- `ORDER BY` + aggregate functions: top 5 best-selling events by revenue
- Subqueries: attendees who bought tickets to ≥3 events by the same organizer (loyalty signal) or whose orders were ever flagged

---

## 9. Advanced Database Features (need ≥4 — plan for 6 to be safe)

| # | Feature | Where it's used |
|---|---|---|
| 1 | **Transactions** | `purchase_ticket` flow: order creation + inventory decrement + ticket/QR issuance + payment record must commit atomically (ROLLBACK on any failure) to prevent overselling |
| 2 | **Triggers** | `AFTER INSERT` on `Tickets` → increments `TicketTypes.quantity_sold`; `BEFORE INSERT` → raises exception if it would exceed `quantity_total`; `AFTER INSERT` on `FraudFlags` with `risk_score > 80` → auto-sets order status to `pending_review` |
| 3 | **Stored procedures/functions** | `purchase_ticket(user_id, ticket_type_id, qty)` — validates availability, creates order/items/tickets in one call; `calculate_risk_score(order_id)` function combining rule + vector signals |
| 4 | **Views** | `event_sales_summary`, `fraud_review_queue` (join FraudFlags + Orders + Users, pending only) |
| 5 | **Full-text search** | `tsvector`/`GIN` index on event title+description for the search bar (combined with vector search for hybrid ranking) |
| 6 | **Vector similarity search** | Fraud reference matching (§6.2) and semantic event discovery (§6.1) |
| 7 (optional) | **NoSQL aggregation** | MongoDB pipeline computing purchase-velocity anomaly scores from `activity_logs` |

---

## 10. Web Application (Next.js)

**Pages/flows**
- Public: event listing with search bar (hybrid full-text + vector) and filters (category, city, date)
- Event detail → checkout (ticket type selection → mock payment → QR ticket issuance)
- Attendee: "My Tickets" wallet with QR codes, order history
- Organizer dashboard: create/edit events & ticket types (uses `event_sales_summary` view), sales charts
- Admin dashboard: **fraud review queue** (from `fraud_review_queue` view) — approve/reject flagged orders, user management
- Gate staff: check-in scanner screen — scans QR, validates against `Tickets.status`, writes `CheckIns`, rejects reused codes

**Architecture**
- Frontend: Next.js (App Router)
- Backend: Next.js Route Handlers as the API layer — no direct DB calls from client
- DB clients: `pg`/Prisma for PostgreSQL, `mongoose` for MongoDB, pgvector queries or Qdrant SDK for vector search
- Config: all credentials via `.env` (never committed), loaded through `process.env`

---

## 11. Auth, Roles, Validation, Security

- **Roles (≥2 required, plan uses 4):** Admin, Organizer, Attendee, Gate Staff — enforced via middleware/route guards (NextAuth.js or JWT-based custom auth)
- **Validation:** `zod` schemas at the API layer mirroring DB `CHECK`/`NOT NULL` constraints — defense in depth (app layer *and* DB layer)
- **Integrity:** FK constraints with explicit `ON DELETE` behavior, transactions for atomic multi-table writes, unique constraints on `email` and `qr_code`
- **Security:** bcrypt password hashing, env-var DB credentials (no hardcoding), parameterized queries only, rate-limiting on `/checkout` and `/login` to blunt bot behavior, HTTPS in deployment

---

## 12. Suggested Timeline

| Week | Milestone |
|---|---|
| 1 | Finalize ER diagram, relational schema, NoSQL & vector data model docs; repo + README skeleton |
| 2 | PostgreSQL DDL, seed data, Next.js scaffold, auth/RBAC |
| 3 | Core CRUD + purchase transaction + triggers/stored procedures |
| 4 | MongoDB activity logging + aggregation pipeline; event embeddings + semantic search |
| 5 | Fraud vector pipeline (feature engineering, reference set, k-NN scoring), admin review queue |
| 6 | Organizer/admin dashboards, check-in scanner, full-text + hybrid search |
| 7 | Testing (test cases for overselling, fraud detection accuracy, RBAC), screenshots, polish |
| 8 | Documentation finalization, demo rehearsal |

---

## 13. Documentation Deliverables (map directly to requirement #14)

Problem statement & objectives (§1) · Scope (§1) · Functional requirements (§10) · ER diagram (§4.1, draw formally) · Relational schema (§4.2) · DB choice justification (§3) · Data dictionary (§4.2 expanded) · SQL/NoSQL/vector implementation details (§4–6) · Important queries (§8) · System architecture diagram (§10) · Screenshots · Test cases & results (overselling prevention, fraud flag accuracy, RBAC enforcement) · Conclusion & future enhancements (e.g., real payment gateway, ML-trained fraud model replacing engineered features).

---

## 14. Originality Note

The differentiator vs. a generic ticketing CRUD app: **fraud is detected via vector similarity to a labeled fraud-reference set combined with real-time NoSQL behavioral aggregation**, not just a hardcoded rule ("flag if qty > 10"). This satisfies the Level 3 requirement that DB paradigm choice be justified by data nature, and pushes the project past basic CRUD into genuine applied database design.
