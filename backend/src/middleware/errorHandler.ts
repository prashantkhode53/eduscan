import { Request, Response, NextFunction } from 'express';

export class AppError extends Error {
  public statusCode: number;
  public isOperational: boolean;

  constructor(message: string, statusCode: number) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    Error.captureStackTrace(this, this.constructor);
  }
}

export const errorHandler = (
  err: Error | AppError,
  _req: Request,
  res: Response,
  _next: NextFunction
): void => {
  const statusCode = (err as AppError).statusCode ?? 500;
  const isOperational = (err as AppError).isOperational ?? false;

  if (process.env.NODE_ENV !== 'production' || isOperational) {
    console.error(`[Error] ${err.message}`);
  } else {
    console.error('[Error] Unhandled server error:', err);
  }

  res.status(statusCode).json({
    success: false,
    // Operational errors carry a user-safe message. For unexpected 500s we
    // still surface the underlying message (prefixed) to aid diagnosis — the
    // app is pre-production and this turns opaque "Internal server error"
    // snackbars into actionable detail.
    message: isOperational ? err.message : `Server error: ${err.message}`,
    ...(process.env.NODE_ENV !== 'production' && { stack: err.stack }),
  });
};

export const notFound = (_req: Request, res: Response): void => {
  res.status(404).json({ success: false, message: 'Route not found' });
};
