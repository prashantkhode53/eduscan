import { Request, Response, NextFunction } from 'express';
import { PoolClient } from 'pg';
import {
  academyQuery,
  academyQueryOne,
  academyExec,
  academyTransaction,
} from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { sendFcmMulticast } from '../../utils/fcm';

const DEFAULT_MAX_CHARS = 500;
const NOTIF_TITLE = 'New Notification';

async function getMaxChars(slug: string): Promise<number> {
  const row = await academyQueryOne<{ value: string }>(
    slug,
    `SELECT value FROM settings WHERE key = 'notification_max_chars'`
  );
  const n = parseInt(row?.value ?? '', 10);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_MAX_CHARS;
}

// ── POST /api/academy/notifications ───────────────────────────────────────────
// Admin broadcast to parents filtered by academic year(s) + course(s).

export async function sendParentNotification(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug, userId, name } = req.academyUser!;
    const body = req.body as {
      message?: string;
      academic_year_ids?: unknown;
      course_ids?: unknown;
    };

    const message = typeof body.message === 'string' ? body.message.trim() : '';
    const yearIds  = Array.isArray(body.academic_year_ids)
      ? body.academic_year_ids.map(String).filter(Boolean) : [];
    const courseIds = Array.isArray(body.course_ids)
      ? body.course_ids.map(String).filter(Boolean) : [];

    if (!message)            return next(new AppError('Notification message is required', 400));
    if (yearIds.length === 0) return next(new AppError('Select at least one academic year', 400));
    if (courseIds.length === 0) return next(new AppError('Select at least one course', 400));

    const maxChars = await getMaxChars(academySlug);
    if (message.length > maxChars) {
      return next(new AppError(`Message exceeds the ${maxChars}-character limit`, 400));
    }

    // ── Eligible recipients: active students in a selected year AND enrolled
    //    (active) in a selected course. DISTINCT collapses multi-course matches.
    const recipients = await academyQuery<{ id: string; parent_fcm_token: string | null }>(
      academySlug,
      `SELECT DISTINCT s.id, s.parent_fcm_token
         FROM students s
         JOIN student_courses sc ON sc.student_id = s.id AND sc.status = 'active'
        WHERE s.status = 'active'
          AND s.academic_year_id = ANY($1::uuid[])
          AND sc.course_id       = ANY($2::uuid[])`,
      [yearIds, courseIds]
    );

    if (recipients.length === 0) {
      return next(new AppError(
        'No active parents match the selected academic year and course.', 404
      ));
    }

    const recipientIds = recipients.map((r) => r.id);
    const tokens = recipients
      .map((r) => r.parent_fcm_token)
      .filter((t): t is string => !!t);

    // ── Persist history row + recipient rows atomically ─────────────────────
    let notificationId = '';
    await academyTransaction(academySlug, async (client: PoolClient) => {
      const { rows } = await client.query<{ id: string }>(
        `INSERT INTO parent_notifications
           (message, academic_year_ids, course_ids, sent_by, sent_by_name, recipient_count)
         VALUES ($1, $2::uuid[], $3::uuid[], $4, $5, $6)
         RETURNING id`,
        [message, yearIds, courseIds, userId, name, recipientIds.length]
      );
      notificationId = rows[0].id;

      // Single multi-row insert via UNNEST — one statement for all recipients.
      await client.query(
        `INSERT INTO parent_notification_recipients (notification_id, student_id)
         SELECT $1, sid FROM UNNEST($2::varchar[]) AS sid
         ON CONFLICT (notification_id, student_id) DO NOTHING`,
        [notificationId, recipientIds]
      );
    });

    // ── Push (best-effort, outside the txn) ─────────────────────────────────
    const result = await sendFcmMulticast(tokens, NOTIF_TITLE, message, {
      type: 'parent_notification',
      notification_id: notificationId,
    });

    // failed = devices that didn't get a push (no token OR send failure).
    const failedCount = (recipientIds.length - tokens.length) + result.failureCount;
    const status = result.successCount === 0
      ? 'failed'
      : failedCount > 0 ? 'partial' : 'sent';

    await academyExec(
      academySlug,
      `UPDATE parent_notifications
          SET success_count = $1, failed_count = $2, status = $3
        WHERE id = $4`,
      [result.successCount, failedCount, status, notificationId]
    );

    console.log(`[academy/notify] ${academySlug} sent id=${notificationId} ` +
      `recipients=${recipientIds.length} ok=${result.successCount} failed=${failedCount}`);

    res.json({
      success: true,
      data: {
        notification_id:  notificationId,
        total_recipients: recipientIds.length,
        success_count:    result.successCount,
        failed_count:     failedCount,
        status,
      },
      message: `Notification sent to ${recipientIds.length} parent(s).`,
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/notifications ────────────────────────────────────────────
// Admin notification history (newest first, paginated).

export async function listSentNotifications(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const page  = Math.max(1, parseInt((req.query['page']  as string) ?? '1', 10));
    const limit = Math.min(50, Math.max(1, parseInt((req.query['limit'] as string) ?? '20', 10)));
    const offset = (page - 1) * limit;

    const rows = await academyQuery<Record<string, unknown>>(
      academySlug,
      `SELECT id, message, academic_year_ids, course_ids,
              sent_by_name, recipient_count, success_count, failed_count,
              status, created_at
         FROM parent_notifications
        ORDER BY created_at DESC
        LIMIT $1 OFFSET $2`,
      [limit, offset]
    );

    res.json({ success: true, data: { notifications: rows, page, limit } });
  } catch (err) { next(err); }
}

// ── GET /api/academy/parent/notifications ─────────────────────────────────────
// Parent's received notifications (newest first, paginated) + unread count.

export async function getParentNotifications(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;
    const page  = Math.max(1, parseInt((req.query['page']  as string) ?? '1', 10));
    const limit = Math.min(50, Math.max(1, parseInt((req.query['limit'] as string) ?? '20', 10)));
    const offset = (page - 1) * limit;

    const [rows, unread] = await Promise.all([
      academyQuery<Record<string, unknown>>(
        academySlug,
        `SELECT pn.id, pn.message, pn.created_at, r.is_read, r.read_at
           FROM parent_notification_recipients r
           JOIN parent_notifications pn ON pn.id = r.notification_id
          WHERE r.student_id = $1
          ORDER BY pn.created_at DESC
          LIMIT $2 OFFSET $3`,
        [studentId, limit, offset]
      ),
      academyQueryOne<{ count: string }>(
        academySlug,
        `SELECT COUNT(*)::int AS count
           FROM parent_notification_recipients
          WHERE student_id = $1 AND is_read = FALSE`,
        [studentId]
      ),
    ]);

    res.json({
      success: true,
      data: {
        notifications: rows,
        unread_count:  unread ? Number(unread.count) : 0,
        page,
        limit,
      },
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/parent/notifications/latest ──────────────────────────────
// Single most-recent notification for the parent (drives the dashboard ticker).

export async function getLatestParentNotification(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;

    const row = await academyQueryOne<Record<string, unknown>>(
      academySlug,
      `SELECT pn.id, pn.message, pn.created_at, r.is_read
         FROM parent_notification_recipients r
         JOIN parent_notifications pn ON pn.id = r.notification_id
        WHERE r.student_id = $1
        ORDER BY pn.created_at DESC
        LIMIT 1`,
      [studentId]
    );

    res.json({ success: true, data: { latest: row } });
  } catch (err) { next(err); }
}

// ── POST /api/academy/parent/notifications/:id/read ───────────────────────────

export async function markNotificationRead(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;
    const { id } = req.params;

    const { rowCount } = await academyExec(
      academySlug,
      `UPDATE parent_notification_recipients
          SET is_read = TRUE, read_at = NOW()
        WHERE notification_id = $1 AND student_id = $2 AND is_read = FALSE`,
      [id, studentId]
    );

    res.json({ success: true, data: { updated: rowCount } });
  } catch (err) { next(err); }
}
