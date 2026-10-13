/**
 * lib/db/mongodb.ts
 *
 * LEARNING NOTE:
 * MongoDB is our NoSQL database for activity logs (clicks, page views,
 * checkout attempts). We use Mongoose, which adds "schemas" to MongoDB
 * even though MongoDB is schema-flexible — this gives us TypeScript types.
 *
 * Same global-variable trick to avoid multiple connections during dev.
 */

import mongoose from 'mongoose';

declare global {
  // eslint-disable-next-line no-var
  var __mongoConnection: typeof mongoose | undefined;
}

const MONGODB_URI = process.env.MONGODB_URI!;

if (!MONGODB_URI) {
  throw new Error('Please set MONGODB_URI in .env.local');
}

async function connectMongo() {
  if (global.__mongoConnection) {
    return global.__mongoConnection;
  }

  const conn = await mongoose.connect(MONGODB_URI, {
    dbName: 'eventguard_logs',
  });

  if (process.env.NODE_ENV !== 'production') {
    global.__mongoConnection = conn;
  }

  console.log('✅ MongoDB connected');
  return conn;
}

export default connectMongo;


// ──────────────────────────────────────────────────────────────
// MONGOOSE SCHEMAS (MongoDB collections)
// LEARNING NOTE: Even though MongoDB doesn't enforce a schema,
// we define one in Mongoose to get TypeScript safety and validation.
// ──────────────────────────────────────────────────────────────

/**
 * ActivityLog — every user action (click, view, checkout attempt)
 * gets logged here for fraud signal computation.
 */
const activityLogSchema = new mongoose.Schema(
  {
    user_id:           { type: Number, required: true, index: true },
    session_id:        { type: String, required: true },
    action: {
      type: String,
      enum: ['view_event', 'add_to_cart', 'checkout_attempt', 'payment_attempt', 'login', 'signup'],
      required: true,
    },
    event_id:          { type: Number },   // which event they were looking at
    metadata:          { type: mongoose.Schema.Types.Mixed },  // extra context (page, referrer, etc.)
    ip_address:        { type: String, index: true },
    device_fingerprint: { type: String },
    timestamp:         { type: Date, default: Date.now, index: true },
  },
  { collection: 'activity_logs' }
);

// Compound index for fraud velocity queries:
// "how many checkout attempts from this IP in the last 60 seconds?"
activityLogSchema.index({ user_id: 1, timestamp: -1 });
activityLogSchema.index({ ip_address: 1, timestamp: -1 });

export const ActivityLog =
  mongoose.models.ActivityLog ||
  mongoose.model('ActivityLog', activityLogSchema);


/**
 * Review — event reviews from attendees
 */
const reviewSchema = new mongoose.Schema(
  {
    event_id:   { type: Number, required: true, index: true },
    user_id:    { type: Number, required: true },
    rating:     { type: Number, required: true, min: 1, max: 5 },
    comment:    { type: String },
    created_at: { type: Date, default: Date.now },
  },
  { collection: 'reviews' }
);

export const Review =
  mongoose.models.Review || mongoose.model('Review', reviewSchema);


/**
 * Notification — in-app notifications for users
 */
const notificationSchema = new mongoose.Schema(
  {
    user_id:    { type: Number, required: true, index: true },
    type:       { type: String, required: true },   // e.g., 'ticket_issued', 'fraud_flagged'
    message:    { type: String, required: true },
    read:       { type: Boolean, default: false },
    created_at: { type: Date, default: Date.now },
  },
  { collection: 'notifications' }
);

export const Notification =
  mongoose.models.Notification ||
  mongoose.model('Notification', notificationSchema);
