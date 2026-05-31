const Joi = require('joi');
const { isValidPhone } = require('../utils/phoneFormatter');

const phoneField = Joi.string().custom((value, helpers) => {
  if (!isValidPhone(value)) return helpers.error('any.invalid');
  return value;
}, 'phone-validation');

const SCHEMAS = {
  sendCheckin: Joi.object({
    phone:       phoneField.required(),
    parentName:  Joi.string().min(1).max(100).trim().required(),
    studentName: Joi.string().min(1).max(100).trim().required(),
    time:        Joi.string().min(1).max(30).trim().required(),
  }),
  sendCheckout: Joi.object({
    phone:       phoneField.required(),
    parentName:  Joi.string().min(1).max(100).trim().required(),
    studentName: Joi.string().min(1).max(100).trim().required(),
    time:        Joi.string().min(1).max(30).trim().required(),
  }),
  sendCustom: Joi.object({
    phone:   phoneField.required(),
    message: Joi.string().min(1).max(1000).trim().required(),
  }),
};

function validate(schemaName) {
  return (req, res, next) => {
    const schema = SCHEMAS[schemaName];
    if (!schema) return next();

    const { error, value } = schema.validate(req.body, { abortEarly: false });
    if (error) {
      const msg = error.details.map((d) => d.message).join('; ');
      return res.status(400).json({ success: false, message: msg });
    }

    req.body = value; // use sanitized / trimmed values
    next();
  };
}

module.exports = { validate };
