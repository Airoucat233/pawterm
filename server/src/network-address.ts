import { networkInterfaces, type NetworkInterfaceInfo } from 'node:os';

export interface AdvertisedAddress {
  name: string;
  address: string;
  priority: number;
}

export interface NetworkAddressServiceOptions {
  pollMs?: number;
  getInterfaces?: () => InterfaceMap;
  onChange?: (current: AdvertisedAddress | null, previous: AdvertisedAddress | null) => void;
}

export interface NetworkAddressService {
  start: () => void;
  stop: () => void;
  getCurrent: () => AdvertisedAddress | null;
}

type InterfaceMap = NodeJS.Dict<NetworkInterfaceInfo[]>;

export function selectAdvertisedAddress(ifaces: InterfaceMap): AdvertisedAddress | null {
  const candidates: AdvertisedAddress[] = [];
  for (const [name, infos] of Object.entries(ifaces)) {
    for (const info of infos ?? []) {
      if (info.internal || info.family !== 'IPv4') continue;
      if (isLinkLocal(info.address)) continue;
      candidates.push({
        name,
        address: info.address,
        priority: addressPriority(name, info.address),
      });
    }
  }
  candidates.sort((a, b) => b.priority - a.priority || a.name.localeCompare(b.name));
  return candidates[0] ?? null;
}

export function createNetworkAddressService(
  opts: NetworkAddressServiceOptions = {},
): NetworkAddressService {
  const pollMs = opts.pollMs ?? 5_000;
  const getInterfaces = opts.getInterfaces ?? networkInterfaces;
  let current = selectAdvertisedAddress(getInterfaces());
  let timer: ReturnType<typeof setInterval> | null = null;

  function check(): void {
    const next = selectAdvertisedAddress(getInterfaces());
    if (sameAddress(current, next)) return;
    const previous = current;
    current = next;
    opts.onChange?.(current, previous);
  }

  return {
    start() {
      if (timer) return;
      check();
      timer = setInterval(check, pollMs);
      timer.unref?.();
    },
    stop() {
      if (!timer) return;
      clearInterval(timer);
      timer = null;
    },
    getCurrent() {
      return current;
    },
  };
}

function sameAddress(a: AdvertisedAddress | null, b: AdvertisedAddress | null): boolean {
  return a?.name === b?.name && a?.address === b?.address;
}

function addressPriority(name: string, address: string): number {
  const iface = name.toLowerCase();
  const physicalBonus = /^(en|wl|wlan|eth)/.test(iface) ? 100 : 0;
  if (address.startsWith('192.168.')) return physicalBonus + 400;
  if (is172Private(address)) return physicalBonus + 350;
  if (address.startsWith('10.')) return physicalBonus + 300;
  if (address.startsWith('100.64.')) return 150;
  return physicalBonus + 50;
}

function is172Private(address: string): boolean {
  const parts = address.split('.');
  if (parts[0] !== '172') return false;
  const second = Number(parts[1]);
  return second >= 16 && second <= 31;
}

function isLinkLocal(address: string): boolean {
  return address.startsWith('169.254.');
}
