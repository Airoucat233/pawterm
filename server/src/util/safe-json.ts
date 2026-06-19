/**
 * 循环引用安全的深拷贝。把已访问过的对象替换成 String(v)，保证返回值一定能
 * JSON.stringify 而不抛 "Converting circular structure to JSON"。
 *
 * 用于 native 事件透传（P2）：SDK / Codex 的原生事件可能带 parent/self 指针
 * 等循环结构，挂到 wire 上前必须先 sanitize，否则整条 SSE 序列化会崩。
 */
export function safeClone(v: unknown, seen = new WeakSet<object>()): unknown {
  if (v === null || v === undefined) return v;
  if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
    return v;
  }
  if (typeof v === 'object') {
    if (seen.has(v)) return String(v);
    seen.add(v);
  }
  if (Array.isArray(v)) return v.map((item) => safeClone(item, seen));
  if (typeof v === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = safeClone(val, seen);
    }
    return out;
  }
  return String(v);
}
