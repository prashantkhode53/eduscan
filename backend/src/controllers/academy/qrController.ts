import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyExec } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';

interface QrRow {
  id: string;
  name: string;
  description: string | null;
  image_data: string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

// ── GET /api/academy/qr-codes ─────────────────────────────────────────────────

export async function listQrCodes(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const rows = await academyQuery<Omit<QrRow, 'image_data'>>(
      academySlug,
      // Return image_data only in the list so the client can render previews;
      // keeping it lets the edit form pre-populate without a second request.
      `SELECT id, name, description, image_data, is_active, created_at, updated_at
       FROM qr_codes ORDER BY is_active DESC, created_at DESC`
    );
    res.json({ success: true, data: rows });
  } catch (err) { next(err); }
}

// ── GET /api/academy/qr-codes/active ─────────────────────────────────────────

export async function getActiveQrCode(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const row = await academyQueryOne<QrRow>(
      academySlug,
      `SELECT id, name, description, image_data, is_active, created_at, updated_at
       FROM qr_codes WHERE is_active = TRUE LIMIT 1`
    );
    // 200 with data:null when no QR is configured (not a 404 — non-fatal)
    res.json({ success: true, data: row ?? null });
  } catch (err) { next(err); }
}

// ── POST /api/academy/qr-codes ────────────────────────────────────────────────

export async function createQrCode(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { name, description, image_data, is_active = false } =
      req.body as {
        name: string; description?: string;
        image_data: string; is_active?: boolean;
      };

    if (!name?.trim())   return next(new AppError('QR name is required', 400));
    if (!image_data)     return next(new AppError('QR image is required', 400));
    if (!image_data.startsWith('data:image') && image_data.length < 100) {
      return next(new AppError('Invalid QR image data', 400));
    }

    // If this one is active, deactivate all others first
    if (is_active) {
      await academyExec(academySlug, `UPDATE qr_codes SET is_active = FALSE`);
    }

    const row = await academyQueryOne<QrRow>(
      academySlug,
      `INSERT INTO qr_codes (name, description, image_data, is_active)
       VALUES ($1, $2, $3, $4) RETURNING *`,
      [name.trim(), description?.trim() ?? null, image_data, is_active]
    );
    res.status(201).json({ success: true, data: row, message: 'QR code created' });
  } catch (err) { next(err); }
}

// ── PUT /api/academy/qr-codes/:id ────────────────────────────────────────────

export async function updateQrCode(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const { name, description, image_data, is_active } =
      req.body as Partial<QrRow>;

    const existing = await academyQueryOne<{ id: string }>(
      academySlug, `SELECT id FROM qr_codes WHERE id = $1`, [id]
    );
    if (!existing) return next(new AppError('QR code not found', 404));

    if (is_active) {
      await academyExec(
        academySlug,
        `UPDATE qr_codes SET is_active = FALSE WHERE id != $1`, [id]
      );
    }

    const row = await academyQueryOne<QrRow>(
      academySlug,
      `UPDATE qr_codes SET
         name        = COALESCE($1, name),
         description = $2,
         image_data  = COALESCE($3, image_data),
         is_active   = COALESCE($4, is_active),
         updated_at  = NOW()
       WHERE id = $5 RETURNING *`,
      [
        name?.trim() ?? null,
        description !== undefined ? (description?.trim() ?? null) : undefined,
        image_data ?? null,
        is_active ?? null,
        id,
      ]
    );
    res.json({ success: true, data: row, message: 'QR code updated' });
  } catch (err) { next(err); }
}

// ── PATCH /api/academy/qr-codes/:id/activate ─────────────────────────────────
// Sets one QR as active and deactivates all others (single-active enforcement).

export async function activateQrCode(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const existing = await academyQueryOne<{ id: string }>(
      academySlug, `SELECT id FROM qr_codes WHERE id = $1`, [id]
    );
    if (!existing) return next(new AppError('QR code not found', 404));

    // Atomic: deactivate all, then activate the chosen one
    await academyExec(academySlug, `UPDATE qr_codes SET is_active = FALSE`);
    await academyExec(
      academySlug,
      `UPDATE qr_codes SET is_active = TRUE, updated_at = NOW() WHERE id = $1`,
      [id]
    );
    res.json({ success: true, message: 'QR code activated' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/qr-codes/:id ─────────────────────────────────────────

export async function deleteQrCode(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const { rowCount } = await academyExec(
      academySlug, `DELETE FROM qr_codes WHERE id = $1`, [id]
    );
    if (rowCount === 0) return next(new AppError('QR code not found', 404));
    res.json({ success: true, message: 'QR code deleted' });
  } catch (err) { next(err); }
}
