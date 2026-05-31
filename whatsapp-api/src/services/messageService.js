const whatsappService = require('./whatsappService');
const { formatToWhatsApp } = require('../utils/phoneFormatter');
const { query } = require('../config/database');
const logger = require('../utils/logger');

const MAX_RETRIES    = 3;
const RETRY_BASE_MS  = 2_000;

// ── Message templates ────────────────────────────────────────────────────────

const TEMPLATES = {
  checkin({ parentName, studentName, time }) {
    return `Hello ${parentName},\n${studentName} has successfully checked in at ${time}.\n\n_Sent by EduScan_`;
  },
  checkout({ parentName, studentName, time }) {
    return `Hello ${parentName},\n${studentName} has successfully checked out at ${time}.\n\n_Sent by EduScan_`;
  },
  custom({ message }) {
    return message;
  },
};

// ── Public API ───────────────────────────────────────────────────────────────

/**
 * Send a WhatsApp message with automatic retry and DB logging.
 * @param {{ phone: string, messageType: string, templateData: object }} opts
 */
async function sendMessage({ phone, messageType, templateData }) {
  const templateFn = TEMPLATES[messageType];
  if (!templateFn) throw new Error(`Unknown message type: ${messageType}`);

  const waId    = formatToWhatsApp(phone);
  const content = templateFn(templateData);
  const logId   = await _createLog(phone, messageType, content);

  let lastErr = null;
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      await whatsappService.sendMessage(waId, content);
      await _updateLog(logId, 'sent', null, attempt - 1);
      return { success: true, logId, message: content };
    } catch (err) {
      lastErr = err;
      logger.warn(`Send attempt ${attempt}/${MAX_RETRIES} failed (${phone}): ${err.message}`);
      if (attempt < MAX_RETRIES) {
        await _sleep(RETRY_BASE_MS * attempt); // exponential back-off: 2s, 4s
      }
    }
  }

  await _updateLog(logId, 'failed', lastErr.message, MAX_RETRIES);
  throw new Error(`Failed after ${MAX_RETRIES} attempts: ${lastErr.message}`);
}

async function getMessageStats() {
  try {
    const today = new Date().toISOString().slice(0, 10);
    const { rows } = await query(
      `SELECT
         COUNT(*)                                             AS total_today,
         COUNT(*) FILTER (WHERE delivery_status = 'sent')    AS sent_today,
         COUNT(*) FILTER (WHERE delivery_status = 'failed')  AS failed_today,
         MAX(sent_at)                                         AS last_sent_at
       FROM whatsapp_message_logs
       WHERE created_at >= $1::date`,
      [today]
    );
    return rows[0];
  } catch (err) {
    logger.warn('Stats query failed:', err.message);
    return { total_today: 0, sent_today: 0, failed_today: 0, last_sent_at: null };
  }
}

// ── Internal helpers ─────────────────────────────────────────────────────────

async function _createLog(phone, messageType, content) {
  try {
    const { rows } = await query(
      `INSERT INTO whatsapp_message_logs (phone_number, message_type, message_content)
       VALUES ($1, $2, $3) RETURNING id`,
      [phone, messageType, content]
    );
    return rows[0].id;
  } catch (err) {
    logger.warn('Log create failed:', err.message);
    return null;
  }
}

async function _updateLog(logId, status, errorMsg, retryCount) {
  if (!logId) return;
  try {
    await query(
      `UPDATE whatsapp_message_logs
       SET delivery_status = $1,
           error_message   = $2,
           retry_count     = $3,
           sent_at         = CASE WHEN $1 = 'sent' THEN NOW() ELSE sent_at END,
           updated_at      = NOW()
       WHERE id = $4`,
      [status, errorMsg, retryCount, logId]
    );
  } catch (err) {
    logger.warn('Log update failed:', err.message);
  }
}

function _sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = { sendMessage, getMessageStats };
