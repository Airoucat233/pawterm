import { Bonjour, type Service } from 'bonjour-service';

export interface MdnsOptions {
  port: number;
  serverId: string;
  hostname: string;
  version: string;
  getPairingState: () => 'open' | 'closed';
}

function safeStop(svc: Service, cb?: () => void): void {
  if (typeof svc.stop === 'function') {
    svc.stop(cb);
  } else if (cb) {
    cb();
  }
}

/**
 * Start mDNS advertisement for the PawTerm server.
 * Returns a cleanup function that stops the advertisement.
 */
export function startMdns(opts: MdnsOptions): () => void {
  let bonjour: Bonjour | null = null;
  let service: Service | null = null;
  let interval: ReturnType<typeof setInterval> | null = null;

  try {
    bonjour = new Bonjour();
    service = bonjour.publish({
      name: `PawTerm on ${opts.hostname}`,
      type: 'pawterm',
      port: opts.port,
      protocol: 'tcp',
      txt: {
        serverId: opts.serverId,
        version: opts.version,
        pairing: opts.getPairingState(),
      },
    });

    let lastPairingState = opts.getPairingState();

    // Poll pairing state every 5s and republish TXT if it changed
    interval = setInterval(() => {
      const current = opts.getPairingState();
      if (current !== lastPairingState && service && bonjour) {
        lastPairingState = current;
        const capturedBonjour = bonjour;
        const capturedService = service;
        try {
          safeStop(capturedService, () => {
            service = capturedBonjour.publish({
              name: `PawTerm on ${opts.hostname}`,
              type: 'pawterm',
              port: opts.port,
              protocol: 'tcp',
              txt: {
                serverId: opts.serverId,
                version: opts.version,
                pairing: current,
              },
            });
          });
        } catch {
          // ignore republish errors
        }
      }
    }, 5000);
  } catch {
    // mDNS is best-effort — if it fails (e.g. permission denied), don't crash the server
  }

  return () => {
    if (interval) clearInterval(interval);
    try {
      if (service) safeStop(service);
      if (bonjour) bonjour.destroy();
    } catch {
      // ignore cleanup errors
    }
  };
}
