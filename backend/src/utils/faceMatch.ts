import { Student } from '../types';

export function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0;
  let magA = 0;
  let magB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    magA += a[i] * a[i];
    magB += b[i] * b[i];
  }
  const denom = Math.sqrt(magA) * Math.sqrt(magB);
  if (denom === 0) return 0;
  return dot / denom;
}

export function findBestMatch(
  incoming: number[],
  students: Student[],
  threshold: number
): { student: Student; confidence: number } | null {
  let best: { student: Student; confidence: number } | null = null;
  for (const s of students) {
    const score = cosineSimilarity(incoming, s.face_embedding);
    if (score >= threshold && (!best || score > best.confidence)) {
      best = { student: s, confidence: Math.round(score * 10000) / 10000 };
    }
  }
  return best;
}
