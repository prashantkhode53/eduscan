import nodemailer from 'nodemailer';
import dotenv from 'dotenv';
dotenv.config();

const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: Number(process.env.SMTP_PORT) || 587,
  secure: false,
  auth: {
    user: process.env.SMTP_USER,
    pass: process.env.SMTP_PASS,
  },
});

export async function sendOtpEmail(to: string, otp: string, adminName: string): Promise<void> {
  await transporter.sendMail({
    from: process.env.SMTP_FROM,
    to,
    subject: 'EduScan — Password Reset OTP',
    html: `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;">
        <h2 style="color:#1A56DB;">EduScan Password Reset</h2>
        <p>Hello ${adminName},</p>
        <p>Your one-time password (OTP) for resetting your EduScan admin password is:</p>
        <div style="font-size:32px;font-weight:bold;letter-spacing:8px;color:#1A56DB;text-align:center;padding:16px;background:#f0f4ff;border-radius:8px;">
          ${otp}
        </div>
        <p>This OTP is valid for <strong>10 minutes</strong>. Do not share it with anyone.</p>
        <p style="color:#888;font-size:12px;">If you did not request this, please ignore this email.</p>
      </div>
    `,
  });
}

export async function sendAbsenceAlert(
  to: string,
  studentName: string,
  className: string,
  consecutiveDays: number
): Promise<void> {
  await transporter.sendMail({
    from: process.env.SMTP_FROM,
    to,
    subject: `EduScan — Absence Alert: ${studentName}`,
    html: `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;">
        <h2 style="color:#E53E3E;">Absence Alert</h2>
        <p>This is an automated alert from EduScan.</p>
        <p>Student <strong>${studentName}</strong> (Class: ${className}) has been absent for
        <strong>${consecutiveDays} consecutive days</strong>.</p>
        <p>Please contact the parent/guardian immediately.</p>
        <p style="color:#888;font-size:12px;">EduScan — Know who's present. Always.</p>
      </div>
    `,
  });
}
