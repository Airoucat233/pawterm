import type { FastifyServerOptions } from 'fastify';

import { settings } from './config.js';

const PRETTY_OPTIONS = {
  colorize: true,
  translateTime: 'HH:MM:ss.l',
  ignore: 'pid,hostname,reqId,req,res,responseTime',
  // responseTime is formatted manually (rounded to integer ms) in the onResponse hook
  messageFormat: '{if reqId}[{reqId}] {end}{msg}{if req} {req.method} {req.url}{end}{if res} → {res.statusCode}{end}{if responseTime} ({responseTime}ms){end}',
  singleLine: true,
};

export function buildLoggerOptions(): FastifyServerOptions['logger'] {
  const { logLevel: level, logFormat: format, logFile } = settings;

  if (!logFile) {
    if (format === 'json') return { level };
    return { level, transport: { target: 'pino-pretty', options: PRETTY_OPTIONS } };
  }

  const fileTarget = format === 'json'
    ? { target: 'pino/file', options: { destination: logFile, append: true, mkdir: true }, level }
    : { target: 'pino-pretty', options: { ...PRETTY_OPTIONS, colorize: false, destination: logFile, append: true, mkdir: true }, level };
  return {
    level,
    transport: {
      targets: [
        format === 'json'
          ? { target: 'pino/file', options: { destination: 1 }, level }
          : { target: 'pino-pretty', options: { ...PRETTY_OPTIONS, destination: 1 }, level },
        fileTarget,
      ],
    },
  };
}

/** Paths whose request/response logs are suppressed (health-check noise). */
export const SILENT_PATHS = new Set(['/health']);
