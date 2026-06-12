import { Request, Response, NextFunction } from 'express';
import { randomUUID } from 'crypto';

export class AppError extends Error {
  public statusCode: number;
  public isOperational: boolean;
  public data?: Record<string, unknown>;

  constructor(message: string, statusCode: number, data?: Record<string, unknown>) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    this.data = data;
    Error.captureStackTrace(this, this.constructor);
  }
}

/** Shape of a node-postgres error (subset we care about). All fields optional. */
interface PgError extends Error {
  code?: string;        // SQLSTATE, e.g. '23505'
  detail?: string;
  constraint?: string;
  column?: string;
  table?: string;
  schema?: string;
}

// SQLSTATE codes that indicate a client-fixable problem (bad/duplicate input)
// rather than a server/schema fault. These are returned as 400; everything else
// categorized stays 500 (retryable / needs support).
const PG_CLIENT_CODES = new Set(['23505', '23502', '23514', '22P02', '22001', '23503']);

/**
 * Map a PostgreSQL SQLSTATE to a safe, user-meaningful message + category.
 * We deliberately do NOT expose the raw SQL, table contents, or stack — only the
 * standard error code and (where harmless) the offending column/constraint name,
 * which are not secrets and make the failure actionable. Returns null if the
 * error is not a recognised pg error.
 */
function categorizePgError(err: PgError): { message: string; category: string } | null {
  if (!err.code) return null;
  const col = err.column ? ` (field: ${err.column})` : '';
  switch (err.code) {
    case '23505': // unique_violation
      return { category: 'database', message: 'This record already exists (a duplicate value was rejected).' };
    case '23503': // foreign_key_violation
      return { category: 'database', message: 'A referenced record is missing or invalid (e.g. course or subject not found).' };
    case '23502': // not_null_violation
      return { category: 'database', message: `A required field was missing${col}.` };
    case '23514': // check_violation
      return { category: 'database', message: 'A submitted value failed a validation rule.' };
    case '22P02': // invalid_text_representation
      return { category: 'database', message: 'A submitted value had an invalid format (e.g. a malformed ID).' };
    case '22001': // string_data_right_truncation
      return { category: 'database', message: 'A submitted value was too long.' };
    case '42703': // undefined_column
      return { category: 'schema', message: 'The database is missing a required column. Please contact support (the server may need a redeploy).' };
    case '42P01': // undefined_table
      return { category: 'schema', message: 'A required database table is missing. Please contact support.' };
    case '40001': // serialization_failure
    case '40P01': // deadlock_detected
      return { category: 'database', message: 'The server was briefly busy. Please try again.' };
    case '57014': // query_canceled (statement timeout)
      return { category: 'database', message: 'The database took too long to respond. Please try again.' };
    default:
      // Any other SQLSTATE (5-char alphanumeric) is still a DB error — surface a
      // safe category instead of the fully-generic message.
      if (/^[0-9A-Z]{5}$/.test(err.code)) {
        return { category: 'database', message: `A database error occurred (code ${err.code}). Please try again.` };
      }
      return null;
  }
}

export const errorHandler = (
  err: Error | AppError,
  req: Request,
  res: Response,
  _next: NextFunction
): void => {
  const appErr = err as AppError;
  const isOperational = appErr.isOperational ?? false;
  const isProd = process.env.NODE_ENV === 'production';

  // Short, non-sensitive reference shared between the server log and the client
  // response so a user-reported failure can be located in the logs instantly.
  const ref = randomUUID().slice(0, 8);

  // Context that makes a log line actionable without leaking secrets.
  const ctx = {
    ref,
    method: req.method,
    path: req.originalUrl,
    academy: (req as Request & { academyUser?: { academySlug?: string } }).academyUser?.academySlug,
  };

  let statusCode = appErr.statusCode ?? 500;
  let clientMessage: string;
  let category: string | undefined;

  if (isOperational) {
    // Thrown deliberately (AppError) — message is already user-safe.
    clientMessage = err.message;
    console.error(`[Error] ref=${ref} ${ctx.method} ${ctx.path}`
      + (ctx.academy ? ` academy=${ctx.academy}` : '')
      + ` ${err.message}`);
  } else {
    // Unexpected error — try to categorise (most commonly a DB error) so the
    // client gets a specific reason instead of "Something went wrong".
    const pg = categorizePgError(err as PgError);
    if (pg) {
      category = pg.category;
      clientMessage = pg.message;
      const pgErr = err as PgError;
      if (PG_CLIENT_CODES.has(pgErr.code!)) statusCode = 400;
      console.error(`[Error] ref=${ref} ${ctx.method} ${ctx.path}`
        + (ctx.academy ? ` academy=${ctx.academy}` : '')
        + ` PG ${pgErr.code} ${pg.category}`
        + (pgErr.constraint ? ` constraint=${pgErr.constraint}` : '')
        + (pgErr.column ? ` column=${pgErr.column}` : '')
        + (pgErr.table ? ` table=${pgErr.table}` : '')
        + (pgErr.detail ? ` detail=${pgErr.detail}` : ''));
    } else {
      category = 'server';
      // Still avoid leaking internals in production, but the ref makes it
      // traceable; non-prod gets the real message inline for fast debugging.
      clientMessage = isProd
        ? `Something went wrong (ref: ${ref}). Please try again, or report this code to support.`
        : `Server error: ${err.message}`;
    }
    // Always log the full error + stack server-side so 500s stay diagnosable.
    console.error(`[Error] ref=${ref} Unhandled error on ${ctx.method} ${ctx.path}`
      + (ctx.academy ? ` academy=${ctx.academy}` : ''), err);
  }

  res.status(statusCode).json({
    success: false,
    message: clientMessage,
    error_ref: ref,
    ...(category ? { category } : {}),
    // Structured data only for operational errors (e.g. FACE_DUPLICATE 409) —
    // never leak internal data from unexpected 500s.
    ...(isOperational && appErr.data ? { data: appErr.data } : {}),
    ...(!isProd && { stack: err.stack }),
  });
};

export const notFound = (_req: Request, res: Response): void => {
  res.status(404).json({ success: false, message: 'Route not found' });
};
