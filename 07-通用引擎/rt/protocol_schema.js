// protocol_schema.js —— ⚠ 生成文件，勿手改
//
// 单一来源：protocol.schema.json（生成器 tools/gen-protocol-schema.mjs）
// ★ 加载顺序：本文件必须**先于** protocol_bin.js（见 client.html 的 <script> 顺序），
//   否则 protocol_bin.js 会抛「schema 未加载」而不是静默用错常量。
(function (root) {
  'use strict';
  const S = {
    MAGIC: 21076,
    MAGIC0: 82,
    MAGIC1: 84,
    VERSION: 3,
    FIX: 16,
    PHASES: ["day", "dusk", "night"],
    SEASONS: ["autumn", "winter", "spring", "summer"],
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = S;
  if (typeof window !== 'undefined') window.ProtocolSchema = S;
})(typeof globalThis !== 'undefined' ? globalThis : this);
