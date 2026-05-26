import { whatsappService } from './service';
import { formatToWhatsApp } from './phoneFormatter';
import { query } from '../db/pool';

const MAX_RETRIES = 3;
const RETRY_BASE  = 2_000;

// ── Message templates ────────────────────────────────────────────────────────

type TemplateData = Record<string, string>;

const TEMPLATES: Record<string, (d: TemplateData) => string> = {
  checkin:  ({ parentName, studentName, time }) =>
    `Hello ${parentName},\n${studentName} has successfully checked in at ${time}.\n\n_Sent by EduScan_`,
  checkout: ({ parentName, studentName, time }) =>
    `Hello ${parentName},\n${studentName} has successfully checked out at ${time}.\n\n_Sent by EduScan_`,
  custom:   ({ message }) => message,
};

// ── Public API ────────────────────────────────────────────────────────────────

export async function sendMessage(opts: {
  phone: string;
  messageType: string;
  templateData: TemplateData;
}): Promise<{ logId: number | null; message: string }> {
  const { phone, messageType, templateData } = opts;
  const tpl = TEMPLATES[messageType];
  if (!tpl) throw new Error(`Unknown message type: ${messageType}`);

  const waId    = formatToWhatsApp(phone);
  const content = tpl(templateData);
  const logId   = await _createLog(phone, messageType, content);

  let lastErr: Error | null = null;

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      await whatsappService.sendMessage(waId, content);
      await _updateLog(logId, 'sent', null, attempt - 1);
      return { logId, message: content };
    } catch (err: unknown) {
      lastErr = err instanceof Error ? err : new Error(String(err));
      console.warn(`[wa-msg] Attempt ${attempt}/${MAX_RETRIES} failed (${phone}): ${lastErr.message}`);
      if (attempt < MAX_RETRIES) await _sleep(RETRY_BASE * attempt);
    }
  }

  await _updateLog(logId, 'failed', lastErr!.message, MAX_RETRIES);
  throw new Error(`Failed after ${MAX_RETRIES} attempts: ${lastErr!.message}`);
}

export async function getMessageStats(): Promise<{
  total_today: string;
  sent_today: string;
  failed_today: string;
  last_sent_at: string | null;
}> {
  try {
    const today = new Date().toISOString().slice(0, 10);
    const rows = await query<{
      total_today: string;
      sent_today: string;
      failed_today: string;
      last_sent_at: string | null;
    }>(`
      SELECT
        COUNT(*)                                             AS total_today,
        COUNT(*) FILTER (WHERE delivery_status = 'sent')    AS sent_today,
        COUNT(*) FILTER (WHERE delivery_status = 'failed')  AS failed_today,
        MAX(sent_at)                                         AS last_sent_at
      FROM whatsapp_logs
      WHERE created_at >= $1::date
    `, [today]);
    return rows[0] ?? { total_today: '0', sent_today: '0', failed_today: '0', last_sent_at: null };
  } catch {
    return { total_today: '0', sent_today: '0', failed_today: '0', last_sent_at: null };
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

async function _createLog(phone: string, messageType: string, content: string): Promise<number | null> {
  try {
    const rows = await query<{ id: number }>(`
      INSERT INTO whatsapp_logs (phone_number, message_type, message_content)
      VALUES ($1, $2, $3) RETURNING id
    `, [phone, messageType, content]);
    return rows[0]?.id ?? null;
  } catch { return null; }
}

async function _updateLog(
  logId: number | null,
  status: string,
  errorMsg: string | null,
  retryCount: number
): Promise<void> {
  if (!logId) return;
  try {
    await query(`
      UPDATE whatsapp_logs
      SET delivery_status = $1,
          error_message   = $2,
          retry_count     = $3,
          sent_at         = CASE WHEN $1 = 'sent' THEN NOW() ELSE sent_at END,
          updated_at      = NOW()
      WHERE id = $4
    `, [status, errorMsg, retryCount, logId]);
  } catch { /* non-fatal */ }
}

function _sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
