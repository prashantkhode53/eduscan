import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { DashboardStats, WeeklyClassStat, ReportFilter } from '../types';
import { AppError } from '../middleware/errorHandler';

export async function getDashboardStats(_req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const today = new Date().toISOString().split('T')[0];

    const totalRow = await queryOne<{ count: string }>(
      `SELECT COUNT(*) as count FROM students WHERE status = 'active'`
    );
    const totalStudents = parseInt(totalRow?.count ?? '0', 10);

    const presentRow = await queryOne<{ count: string }>(
      `SELECT COUNT(*) as count FROM attendance WHERE date = $1 AND status = 'present'`,
      [today]
    );
    const presentToday = parseInt(presentRow?.count ?? '0', 10);

    const absentRow = await queryOne<{ count: string }>(
      `SELECT COUNT(*) as count FROM attendance WHERE date = $1 AND status = 'absent'`,
      [today]
    );
    const absentToday = parseInt(absentRow?.count ?? '0', 10);

    const stats: DashboardStats = {
      total_students: totalStudents,
      present_today: presentToday,
      absent_today: absentToday,
      unknown_faces: 0,
      attendance_percentage:
        totalStudents > 0 ? Math.round((presentToday / totalStudents) * 10000) / 100 : 0,
    };

    res.json({ success: true, data: stats, message: 'Dashboard stats fetched' });
  } catch (err) {
    next(err);
  }
}

export async function getWeeklyReport(_req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const rows = await query<{
      class_grade: string;
      division: string;
      date: string;
      present: string;
      total: string;
    }>(
      `SELECT s.class_grade, s.division, a.date,
              COUNT(*) FILTER (WHERE a.status = 'present') as present,
              COUNT(*) as total
       FROM attendance a
       JOIN students s ON a.student_id = s.id
       WHERE a.date >= CURRENT_DATE - INTERVAL '7 days'
       GROUP BY s.class_grade, s.division, a.date
       ORDER BY a.date, s.class_grade, s.division`
    );

    const stats: WeeklyClassStat[] = rows.map((r) => {
      const present = parseInt(r.present, 10);
      const total = parseInt(r.total, 10);
      return {
        class_grade: r.class_grade,
        division: r.division,
        date: r.date,
        present,
        total,
        percentage: total > 0 ? Math.round((present / total) * 10000) / 100 : 0,
      };
    });

    res.json({ success: true, data: stats, message: 'Weekly report fetched' });
  } catch (err) {
    next(err);
  }
}

export async function getRecentActivity(_req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const rows = await query(
      `SELECT a.id, a.student_id, a.date, a.time_in, a.time_out, a.status, a.checkin_mode,
              s.first_name, s.last_name, s.class_grade, s.division, s.roll_no
       FROM attendance a
       JOIN students s ON a.student_id = s.id
       WHERE a.time_in IS NOT NULL
       ORDER BY a.date DESC, a.time_in DESC
       LIMIT 10`
    );
    res.json({ success: true, data: rows, message: 'Recent activity fetched' });
  } catch (err) {
    next(err);
  }
}

export async function exportReport(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const filter = req.query as ReportFilter;
    const { date_from, date_to, class_grade, division, student_id, format = 'csv' } = filter;

    const conditions: string[] = [];
    const params: unknown[] = [];
    let idx = 1;

    if (date_from) { conditions.push(`a.date >= $${idx++}`); params.push(date_from); }
    if (date_to)   { conditions.push(`a.date <= $${idx++}`); params.push(date_to);   }
    if (student_id){ conditions.push(`a.student_id = $${idx++}`); params.push(student_id); }
    if (class_grade){ conditions.push(`s.class_grade = $${idx++}`); params.push(class_grade); }
    if (division)  { conditions.push(`s.division = $${idx++}`); params.push(division); }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const rows = await query(
      `SELECT s.id as student_id, s.first_name, s.last_name, s.class_grade, s.division, s.roll_no,
              a.date, a.time_in, a.time_out, a.duration_mins, a.status, a.checkin_mode,
              a.confidence_in, a.remarks
       FROM attendance a
       JOIN students s ON a.student_id = s.id
       ${where}
       ORDER BY a.date DESC, s.class_grade, s.roll_no`,
      params
    );

    if (format === 'json') {
      res.json({ success: true, data: rows, message: 'Report exported' });
      return;
    }

    // CSV export
    if (rows.length === 0) {
      return next(new AppError('No data found for the given filters', 404));
    }

    const headers = [
      'student_id', 'first_name', 'last_name', 'class_grade', 'division', 'roll_no',
      'date', 'time_in', 'time_out', 'duration_mins', 'status', 'checkin_mode',
      'confidence_in', 'remarks',
    ];

    const csvLines = [
      headers.join(','),
      ...rows.map((row) => {
        const r = row as Record<string, unknown>;
        return headers
          .map((h) => {
            const val = r[h] ?? '';
            const str = String(val);
            return str.includes(',') || str.includes('"') || str.includes('\n')
              ? `"${str.replace(/"/g, '""')}"`
              : str;
          })
          .join(',');
      }),
    ];

    const csv = csvLines.join('\n');
    const filename = `attendance_${date_from ?? 'all'}_${date_to ?? 'all'}.csv`;

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(csv);
  } catch (err) {
    next(err);
  }
}

export async function getStudentReportSummary(_req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const rows = await query(
      `SELECT s.id, s.first_name, s.last_name, s.class_grade, s.division, s.roll_no,
              COUNT(*) as total_days,
              COUNT(*) FILTER (WHERE a.status = 'present') as present_days,
              COUNT(*) FILTER (WHERE a.status = 'absent') as absent_days,
              COUNT(*) FILTER (WHERE a.status = 'late') as late_days,
              ROUND(
                COUNT(*) FILTER (WHERE a.status = 'present')::numeric /
                NULLIF(COUNT(*), 0) * 100, 2
              ) as percentage
       FROM students s
       LEFT JOIN attendance a ON s.id = a.student_id
       WHERE s.status = 'active'
       GROUP BY s.id, s.first_name, s.last_name, s.class_grade, s.division, s.roll_no
       ORDER BY percentage ASC NULLS LAST`
    );
    res.json({ success: true, data: rows, message: 'Student summary fetched' });
  } catch (err) {
    next(err);
  }
}
