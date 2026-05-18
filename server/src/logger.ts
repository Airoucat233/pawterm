import type { FastifyServerOptions } from 'fastify';

import { settings } from './config.js';

export function buildLoggerOptions(): FastifyServerOptions['logger'] {
  const { logLevel: level, logFormat: format } = settings;

  if (format === 'json') {
    return { level };
  }

  return {
    level,
    transport: {
      target: 'pino-pretty',
      options: {
        colorize: true,
        translateTime: 'HH:MM:ss.l',
        ignore: 'pid,hostname,reqId,req,res,responseTime',
        messageFormat: '{if reqId}[{reqId}] {end}{msg}{if req} {req.method} {req.url}{end}{if res} → {res.statusCode}{end}{if responseTime} ({responseTime}ms){end}',
        singleLine: true,
      },
    },
  };
}
