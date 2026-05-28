import { Request, Response, NextFunction } from 'express';
import { AppError } from '../middleware/errorHandler';

type ValidationRule = {
  field: string;
  required?: boolean;
  type?: 'string' | 'number' | 'array' | 'boolean';
  minLength?: number;
  maxLength?: number;
  pattern?: RegExp;
};

export function validateBody(rules: ValidationRule[]) {
  return (req: Request, _res: Response, next: NextFunction): void => {
    for (const rule of rules) {
      const value = (req.body as Record<string, unknown>)[rule.field];

      if (rule.required && (value === undefined || value === null || value === '')) {
        return next(new AppError(`Field '${rule.field}' is required`, 400));
      }

      if (value === undefined || value === null) continue;

      if (rule.type === 'string' && typeof value !== 'string') {
        return next(new AppError(`Field '${rule.field}' must be a string`, 400));
      }
      if (rule.type === 'number' && typeof value !== 'number') {
        return next(new AppError(`Field '${rule.field}' must be a number`, 400));
      }
      if (rule.type === 'array' && !Array.isArray(value)) {
        return next(new AppError(`Field '${rule.field}' must be an array`, 400));
      }

      if (rule.type === 'string' && typeof value === 'string') {
        if (rule.minLength && value.length < rule.minLength) {
          return next(new AppError(`Field '${rule.field}' must be at least ${rule.minLength} characters`, 400));
        }
        if (rule.maxLength && value.length > rule.maxLength) {
          return next(new AppError(`Field '${rule.field}' must not exceed ${rule.maxLength} characters`, 400));
        }
        if (rule.pattern && !rule.pattern.test(value)) {
          return next(new AppError(`Field '${rule.field}' has invalid format`, 400));
        }
      }
    }
    next();
  };
}

export function validateEmbedding(embedding: unknown): number[] {
  if (!Array.isArray(embedding)) {
    throw new AppError('face_embedding must be an array', 400);
  }
  if (embedding.length !== 128 && embedding.length !== 512) {
    throw new AppError('face_embedding must have 128 or 512 values', 400);
  }
  const nums = embedding.map((v, i) => {
    const n = Number(v);
    if (isNaN(n)) throw new AppError(`face_embedding[${i}] is not a number`, 400);
    return n;
  });
  return nums;
}

export function isValidDate(dateStr: string): boolean {
  const d = new Date(dateStr);
  return !isNaN(d.getTime());
}

export function isValidTime(timeStr: string): boolean {
  return /^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/.test(timeStr);
}
