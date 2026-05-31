/**
 * Normalizes a phone number to WhatsApp chat ID format: <digits>@c.us
 * Handles Indian (10-digit) and international (E.164) numbers.
 */
function formatToWhatsApp(phone) {
  if (!phone) throw new Error('Phone number is required');

  let cleaned = String(phone).replace(/[^\d+]/g, '');

  if (cleaned.startsWith('+')) {
    cleaned = cleaned.slice(1);
  }

  // Bare 10-digit Indian number — prepend country code
  if (cleaned.length === 10) {
    cleaned = `91${cleaned}`;
  }

  if (cleaned.length < 10 || cleaned.length > 15) {
    throw new Error(`Invalid phone number: "${phone}" (expected 10–15 digits)`);
  }

  return `${cleaned}@c.us`;
}

function isValidPhone(phone) {
  try {
    formatToWhatsApp(phone);
    return true;
  } catch {
    return false;
  }
}

module.exports = { formatToWhatsApp, isValidPhone };
