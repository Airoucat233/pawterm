import type { FastifyServerOptions } from 'fastify';

import { settings } from './config.js';

const PRETTY_OPTIONS = {
  colorize: true,
  translateTime: 'HH:MM:ss.l',
  ignore: 'pid,hostname,reqId,req,res,responseTime',
  messageFormat: '{if reqId}[{reqId}] {end}{msg}{if req} {req.method} {req.url}{end}{if res} → {res.statusCode}{end}{if responseTime} ({responseTime}ms){end}',
  singleLine: true,
};

export function buildLoggerOptions(): FastifyServerOptions['logger'] {
  const { logLevel: level, logFormat: format, logFile } = settings;

  if (!logFile) {
    // Single output to stdout.
    if (format === 'json') return { level };
    return { level, transport: { target: 'pino-pretty', options: PRETTY_OPTIONS } };
  }

  // Tee: stdout + file, both using the configured format.
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
