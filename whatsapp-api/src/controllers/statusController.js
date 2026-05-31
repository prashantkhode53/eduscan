const whatsappService = require('../services/whatsappService');
const messageService  = require('../services/messageService');
const logger          = require('../utils/logger');

async function getQrCode(req, res) {
  try {
    const info = whatsappService.getStatusInfo();
    res.json({
      success: true,
      data: {
        status:    info.status,
        connected: info.connected,
        hasQr:     info.hasQr,
        qrData:    info.connected ? null : whatsappService.qrData,
        qrBase64:  info.connected ? null : whatsappService.qrBase64,
      },
    });
  } catch (err) {
    logger.error('[status] getQrCode:', err.message);
    res.status(500).json({ success: false, message: err.message });
  }
}

async function getWhatsappStatus(req, res) {
  try {
    const info  = whatsappService.getStatusInfo();
    const stats = await messageService.getMessageStats();

    res.json({
      success: true,
      data: {
        status:          info.status,
        connected:       info.connected,
        lastConnectedAt: info.lastConnectedAt,
        hasQr:           info.hasQr,
        stats: {
          totalToday:  parseInt(stats.total_today  ?? 0, 10),
          sentToday:   parseInt(stats.sent_today   ?? 0, 10),
          failedToday: parseInt(stats.failed_today ?? 0, 10),
          lastSentAt:  stats.last_sent_at ?? null,
        },
      },
    });
  } catch (err) {
    logger.error('[status] getWhatsappStatus:', err.message);
    res.status(500).json({ success: false, message: err.message });
  }
}

function health(req, res) {
  res.json({
    success: true,
    data: {
      service:   'eduscan-whatsapp-service',
      status:    'healthy',
      uptime:    Math.floor(process.uptime()),
      timestamp: new Date().toISOString(),
      whatsapp:  whatsappService.state,
    },
  });
}

module.exports = { getQrCode, getWhatsappStatus, health };
