const messageService = require('../services/messageService');
const logger = require('../utils/logger');

async function sendCheckin(req, res) {
  try {
    const { phone, parentName, studentName, time } = req.body;
    const result = await messageService.sendMessage({
      phone,
      messageType:  'checkin',
      templateData: { parentName, studentName, time },
    });
    logger.info(`[msg] Check-in sent → ${phone}`);
    res.json({ success: true, data: result });
  } catch (err) {
    logger.error('[msg] sendCheckin error:', err.message);
    res.status(500).json({ success: false, message: err.message });
  }
}

async function sendCheckout(req, res) {
  try {
    const { phone, parentName, studentName, time } = req.body;
    const result = await messageService.sendMessage({
      phone,
      messageType:  'checkout',
      templateData: { parentName, studentName, time },
    });
    logger.info(`[msg] Check-out sent → ${phone}`);
    res.json({ success: true, data: result });
  } catch (err) {
    logger.error('[msg] sendCheckout error:', err.message);
    res.status(500).json({ success: false, message: err.message });
  }
}

async function sendCustom(req, res) {
  try {
    const { phone, message } = req.body;
    const result = await messageService.sendMessage({
      phone,
      messageType:  'custom',
      templateData: { message },
    });
    logger.info(`[msg] Custom message sent → ${phone}`);
    res.json({ success: true, data: result });
  } catch (err) {
    logger.error('[msg] sendCustom error:', err.message);
    res.status(500).json({ success: false, message: err.message });
  }
}

module.exports = { sendCheckin, sendCheckout, sendCustom };
