import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyExec } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';

interface AcademicYearRow {
  id: string;
  academic_year_name: string;
  start_date: string;
  end_date: string;
  status: string;
  is_current_year: boolean;
  created_at: string;
  updated_at: string;
}

// ── GET /api/academy/academic-years ──────────────────────────────────────────

export async function listAcademicYears(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const rows = await academyQuery<AcademicYearRow>(
      academySlug,
      `SELECT * FROM academic_years ORDER BY start_date DESC`
    );
    res.json({ success: true, data: rows });
  } catch (err) { next(err); }
}

// ── GET /api/academy/academic-years/current ───────────────────────────────────

export async function getCurrentAcademicYear(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const row = await academyQueryOne<AcademicYearRow>(
      academySlug,
      `SELECT * FROM academic_years WHERE is_current_year = TRUE LIMIT 1`
    );
    res.json({ success: true, data: row ?? null });
  } catch (err) { next(err); }
}

// ── POST /api/academy/academic-years ─────────────────────────────────────────

export async function createAcademicYear(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      academic_year_name, start_date, end_date,
      status = 'active', is_current_year = false,
    } = req.body as {
      academic_year_name: string; start_date: string; end_date: string;
      status?: string; is_current_year?: boolean;
    };

    if (!academic_year_name?.trim()) return next(new AppError('Academic year name is required', 400));
    if (!start_date) return next(new AppError('Start date is required', 400));
    if (!end_date)   return next(new AppError('End date is required', 400));
    if (new Date(end_date) <= new Date(start_date)) {
      return next(new AppError('End date must be after start date', 400));
    }

    // Unique name check
    const dup = await academyQueryOne(
      academySlug,
      `SELECT id FROM academic_years WHERE LOWER(academic_year_name) = LOWER($1)`,
      [academic_year_name.trim()]
    );
    if (dup) return next(new AppError('Academic year name already exists', 409));

    // Overlap check (active years only)
    const overlap = await academyQueryOne(
      academySlug,
      `SELECT id FROM academic_years
       WHERE status = 'active'
         AND ($1::date, $2::date) OVERLAPS (start_date, end_date)`,
      [start_date, end_date]
    );
    if (overlap) return next(new AppError('Academic year dates overlap with an existing year', 409));

    // Only one current year allowed
    if (is_current_year) {
      await academyExec(academySlug, `UPDATE academic_years SET is_current_year = FALSE`);
    }

    const row = await academyQueryOne<AcademicYearRow>(
      academySlug,
      `INSERT INTO academic_years (academic_year_name, start_date, end_date, status, is_current_year)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [academic_year_name.trim(), start_date, end_date, status, is_current_year]
    );
    res.status(201).json({ success: true, data: row, message: 'Academic year created' });
  } catch (err) { next(err); }
}

// ── PUT /api/academy/academic-years/:id ──────────────────────────────────────

export async function updateAcademicYear(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const { academic_year_name, start_date, end_date, status, is_current_year } =
      req.body as Partial<AcademicYearRow>;

    const existing = await academyQueryOne<AcademicYearRow>(
      academySlug, `SELECT * FROM academic_years WHERE id = $1`, [id]
    );
    if (!existing) return next(new AppError('Academic year not found', 404));

    const newName  = academic_year_name?.trim() ?? existing.academic_year_name;
    const newStart = start_date ?? existing.start_date;
    const newEnd   = end_date   ?? existing.end_date;

    if (new Date(newEnd) <= new Date(newStart)) {
      return next(new AppError('End date must be after start date', 400));
    }

    // Unique name check (exclude self)
    if (academic_year_name) {
      const dup = await academyQueryOne(
        academySlug,
        `SELECT id FROM academic_years WHERE LOWER(academic_year_name) = LOWER($1) AND id != $2`,
        [newName, id]
      );
      if (dup) return next(new AppError('Academic year name already exists', 409));
    }

    // Overlap check (exclude self, active only)
    if (start_date || end_date) {
      const overlap = await academyQueryOne(
        academySlug,
        `SELECT id FROM academic_years
         WHERE status = 'active' AND id != $3
           AND ($1::date, $2::date) OVERLAPS (start_date, end_date)`,
        [newStart, newEnd, id]
      );
      if (overlap) return next(new AppError('Academic year dates overlap with an existing year', 409));
    }

    if (is_current_year === true) {
      await academyExec(
        academySlug, `UPDATE academic_years SET is_current_year = FALSE WHERE id != $1`, [id]
      );
    }

    const row = await academyQueryOne<AcademicYearRow>(
      academySlug,
      `UPDATE academic_years
       SET academic_year_name = COALESCE($1, academic_year_name),
           start_date         = COALESCE($2::date, start_date),
           end_date           = COALESCE($3::date, end_date),
           status             = COALESCE($4, status),
           is_current_year    = COALESCE($5, is_current_year),
           updated_at         = NOW()
       WHERE id = $6 RETURNING *`,
      [
        academic_year_name?.trim() ?? null,
        start_date ?? null,
        end_date   ?? null,
        status     ?? null,
        is_current_year ?? null,
        id,
      ]
    );
    res.json({ success: true, data: row, message: 'Academic year updated' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/academic-years/:id ────────────────────────────────────

export async function deleteAcademicYear(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const active = await academyQueryOne<{ count: string }>(
      academySlug,
      `SELECT COUNT(*) FROM courses WHERE academic_year_id = $1 AND is_active = TRUE`,
      [id]
    );
    if (active && parseInt(active.count) > 0) {
      return next(new AppError('Cannot delete academic year with active courses', 409));
    }

    await academyExec(
      academySlug,
      `UPDATE academic_years
       SET status = 'inactive', is_current_year = FALSE, updated_at = NOW()
       WHERE id = $1`,
      [id]
    );
    res.json({ success: true, message: 'Academic year deleted' });
  } catch (err) { next(err); }
}
