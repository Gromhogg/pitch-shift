// A stand-in for Cloudflare KV, kept in memory (tests and the local test server).
export class MemoryKV {
  constructor() {
    this.data = new Map();
    this.writes = 0;
  }
  async get(key, type) {
    if (!this.data.has(key)) return null;
    const value = this.data.get(key);
    return type === "json" ? JSON.parse(value) : value;
  }
  async put(key, value) {
    this.writes += 1;
    this.data.set(key, String(value));
  }
  async delete(key) {
    this.data.delete(key);
  }
}
