import type { FastifyServerOptions } from 'fastify';

/**
 * Build Fastify logger config.
 *
 * Two modes (controlled by env `PAWTERM_LOG_FORMAT`):
 *   - "pretty" (default in dev): colored, time + level + msg human format.
 *   - "json"   (default in prod): machine-readable single-line JSON (pino).
 *
 * Level controlled by env `PAWTERM_LOG_LEVEL` (default "info").
 */
export function buildLoggerOptions(): FastifyServerOptions['logger'] {
  const level = process.env.PAWTERM_LOG_LEVEL ?? process.env.CC_LOG_LEVEL ?? 'info';
  const format = process.env.PAWTERM_LOG_FORMAT ?? process.env.CC_LOG_FORMAT ?? (process.env.NODE_ENV === 'production' ? 'json' : 'pretty');

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
